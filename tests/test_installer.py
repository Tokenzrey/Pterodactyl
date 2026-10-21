#!/usr/bin/env python3
"""Offline tests for eggs/modpack-installer/installer.py: mock Modrinth / CurseForge / CDN servers on localhost.
The network-dependent parts (Fabric/Forge/NeoForge installers, Mojang manifest) are covered by real runs documented in
docs/verification.md; here they are replaced by packs that already bundle a launcher, or by the built-in Java table."""
import hashlib
import http.server
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("installer", os.path.join(HERE, "..", "eggs", "modpack-installer", "installer.py"))
inst = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inst)


class Mock:
    """Tiny HTTP server: routes = {path: (status, bytes|dict)}; records (path, headers) of every request."""

    def __init__(self):
        self.routes, self.seen = {}, []
        mock = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                path = self.path.split("?")[0]
                mock.seen.append((path, dict(self.headers)))
                status, body = mock.routes.get(path, (404, b"{}"))
                if isinstance(body, (dict, list)):
                    body = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


def zipbytes(files):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        for name, data in files.items():
            z.writestr(name, data)
    return b.getvalue()


def sha(data, algo="sha512"):
    return hashlib.new(algo, data).hexdigest()


class Base(unittest.TestCase):
    def setUp(self):
        self.mock = Mock()
        self.tmp = tempfile.mkdtemp(prefix="ti-")
        self.dest = os.path.join(self.tmp, "server")
        self._saved = (inst.MODRINTH_BASE, inst.CF_BASE, inst.host_allowed, inst.mojang_java_major, inst.public_host)
        inst.MODRINTH_BASE = inst.CF_BASE = self.mock.base
        inst.host_allowed = lambda url, hosts: True            # the mock CDN is http://127.0.0.1
        inst.mojang_java_major = lambda mc: None               # offline: use the built-in table
        inst.public_host = lambda host: True
        inst.http_get.__defaults__ = (None, 1)                 # no retries/sleeps in tests

    def tearDown(self):
        inst.MODRINTH_BASE, inst.CF_BASE, inst.host_allowed, inst.mojang_java_major, inst.public_host = self._saved
        inst.http_get.__defaults__ = (None, 3)
        self.mock.close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **kw):
        return {"MODPACK_SOURCE": "modrinth", "MODPACK_ID": "mypack", **kw}

    def read(self, rel):
        with open(os.path.join(self.dest, rel), "rb") as f:
            return f.read()

    def modrinth_pack(self, files=None, overrides=None, deps=None, version_id="v1"):
        files = files or {"mods/a.jar": b"AAA"}
        index = {"formatVersion": 1, "name": "Test", "versionId": "1.0", "dependencies": deps or {"minecraft": "1.20.1", "fabric-loader": "0.15.0"},
                 "files": []}
        for path, data in files.items():
            self.mock.routes["/cdn/" + path.replace("/", "_")] = (200, data)
            index["files"].append({"path": path, "hashes": {"sha512": sha(data)}, "env": {"server": "required"},
                                   "downloads": [self.mock.base + "/cdn/" + path.replace("/", "_")]})
        archive = {"modrinth.index.json": json.dumps(index)}
        archive.update(overrides or {})
        data = zipbytes(archive)
        self.mock.routes["/cdn/pack.mrpack"] = (200, data)
        v = {"id": version_id, "version_number": "1.0", "name": "Test 1.0", "version_type": "release", "game_versions": ["1.20.1"],
             "files": [{"primary": True, "filename": "pack.mrpack", "url": self.mock.base + "/cdn/pack.mrpack", "hashes": {"sha512": sha(data)}}]}
        self.mock.routes["/v2/project/mypack/version"] = (200, [v])
        return index


class TestPaths(unittest.TestCase):
    def test_safe_rel(self):
        for bad in ("../x", "a/../../x", "/etc/passwd", "C:\\x", "", "a/.."):
            with self.assertRaises(inst.InstallError, msg=bad):
                inst.safe_rel(bad)
        self.assertEqual(inst.safe_rel("mods\\a.jar"), os.path.join("mods", "a.jar"))

    def test_host_allowed(self):
        self.assertTrue(inst.host_allowed("https://cdn.modrinth.com/data/x", inst.MODRINTH_FILE_HOSTS))
        self.assertFalse(inst.host_allowed("http://cdn.modrinth.com/x", inst.MODRINTH_FILE_HOSTS), "plain http refused")
        self.assertFalse(inst.host_allowed("https://evilcdn.modrinth.com.attacker.io/x", inst.MODRINTH_FILE_HOSTS))
        self.assertFalse(inst.host_allowed("https://notgithub.com/x", inst.MODRINTH_FILE_HOSTS))
        self.assertTrue(inst.host_allowed("https://edge.forgecdn.net/files/1/2/a.jar", inst.CF_FILE_HOSTS))

    def test_public_host(self):
        self.assertFalse(inst.public_host("127.0.0.1"))
        self.assertFalse(inst.public_host("169.254.169.254"))
        self.assertFalse(inst.public_host("10.0.0.5"))
        self.assertFalse(inst.public_host("nonexistent.invalid"))

    def test_java_table(self):
        saved = inst.mojang_java_major
        inst.mojang_java_major = lambda mc: None
        try:
            for mc, want in (("26.3", "java_25"), ("1.21.1", "java_21"), ("1.20.5", "java_21"), ("1.20.4", "java_17"), ("1.20.1", "java_17"),
                             ("1.18.2", "java_17"), ("1.17.1", "java_16"), ("1.16.5", "java_8"), ("1.12.2", "java_8")):
                self.assertEqual(inst.java_for(mc), want, mc)
            inst.mojang_java_major = lambda mc: 19      # no yolks image for 19: next one up
            self.assertEqual(inst.java_for("x"), "java_21")
        finally:
            inst.mojang_java_major = saved

    def test_keep_existing(self):
        for p in ("config/a/b.toml", "server.properties", "world/level.dat", "ops.json"):
            self.assertTrue(inst.keep_existing(p), p)
        for p in ("mods/a.jar", "libraries/x.jar", "kubejs/x.js"):
            self.assertFalse(inst.keep_existing(p), p)


class TestInspect(unittest.TestCase):
    def check(self, files, **want):
        p = tempfile.mktemp(suffix=".zip")
        open(p, "wb").write(zipbytes(files))
        info = inst.inspect_server_zip(p)
        os.remove(p)
        for k, v in want.items():
            self.assertEqual(info[k], v, k)

    def test_run_sh_is_most_trusted(self):
        self.check({"run.sh": "java @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.20.1-47.4.0/unix_args.txt",
                    "libraries/net/minecraftforge/forge/1.20.1-47.3.0/x.jar": "x", "mods/a.jar": "1"},
                   mc="1.20.1", loader="forge", loader_version="47.4.0", mods=1)

    def test_neoforge(self):
        self.check({"run.sh": "java @libraries/net/neoforged/neoforge/21.1.77/unix_args.txt"}, loader="neoforge", loader_version="21.1.77")

    def test_libraries_only(self):
        self.check({"pack/libraries/net/minecraftforge/forge/1.19.2-43.2.0/a.jar": "x", "pack/libraries/net/minecraft/server/1.19.2/s.jar": "x"},
                   mc="1.19.2", loader="forge", loader_version="43.2.0")

    def test_fabric_libraries(self):
        self.check({"libraries/net/fabricmc/fabric-loader/0.15.7/a.jar": "x", "libraries/net/minecraft/server/1.20.4/s.jar": "x"},
                   loader="fabric", loader_version="0.15.7", mc="1.20.4")

    def test_installer_jar_name(self):
        self.check({"forge-1.12.2-14.23.5.2860-installer.jar": "x"}, loader="forge", mc="1.12.2", loader_version="14.23.5.2860")


class TestModrinth(Base):
    def test_install_with_bundled_launcher(self):
        self.modrinth_pack(files={"mods/a.jar": b"AAA", "config/c.toml": b"x=1"},
                           overrides={"overrides/fabric-server-launch.jar": "launcher", "overrides/readme.txt": "hi", "server-overrides/readme.txt": "server wins"})
        inst.install(self.env(), self.dest)
        self.assertEqual(self.read("mods/a.jar"), b"AAA")
        self.assertEqual(self.read("readme.txt"), b"server wins")
        self.assertEqual(self.read("launch.args").strip(), b"-jar fabric-server-launch.jar")
        self.assertIn(b"online-mode=true", self.read("server.properties"))
        meta = json.loads(self.read(".ptero-modpack.json"))
        self.assertEqual(meta["minecraft"], "1.20.1")
        self.assertIn("mods/a.jar", meta["files"])
        self.assertNotIn(b"eula=true", b"".join(open(os.path.join(self.dest, f), "rb").read() for f in os.listdir(self.dest) if os.path.isfile(os.path.join(self.dest, f))),
                         "the installer must never accept the EULA")

    def test_download_scratch_is_not_tmp(self):
        # the install container's /tmp is a small tmpfs: the pack must be fetched without touching it
        self.modrinth_pack(files={"mods/a.jar": b"AAA"}, overrides={"overrides/fabric-server-launch.jar": "launcher"})
        saved = tempfile.tempdir
        tempfile.tempdir = os.path.join(self.tmp, "no-such-tmp")
        try:
            inst.install(self.env(), self.dest)
        finally:
            tempfile.tempdir = saved
        self.assertEqual(self.read("mods/a.jar"), b"AAA")
        self.assertEqual([n for n in os.listdir(self.dest) if n.startswith(".ptero-work-")], [], "scratch folder removed afterwards")

    def test_hash_mismatch_aborts(self):
        idx = self.modrinth_pack()
        self.mock.routes["/cdn/mods_a.jar"] = (200, b"TAMPERED")
        with self.assertRaises(inst.InstallError) as c:
            inst.install(self.env(), self.dest)
        self.assertIn("cannot download", str(c.exception))
        self.assertFalse(os.path.exists(os.path.join(self.dest, "launch.args")), "nothing marks a failed install as complete")

    def test_missing_sha512_refused(self):
        idx = self.modrinth_pack(overrides={"overrides/fabric-server-launch.jar": "l"})
        archive = {"modrinth.index.json": json.dumps({**idx, "files": [{"path": "mods/b.jar", "hashes": {}, "downloads": [self.mock.base + "/cdn/x"]}]}),
                   "overrides/fabric-server-launch.jar": "l"}
        data = zipbytes(archive)
        self.mock.routes["/cdn/pack.mrpack"] = (200, data)
        v = self.mock.routes["/v2/project/mypack/version"][1][0]
        v["files"][0]["hashes"]["sha512"] = sha(data)
        with self.assertRaises(inst.InstallError) as c:
            inst.install(self.env(), self.dest)
        self.assertIn("unverifiable", str(c.exception))

    def test_path_traversal_refused(self):
        self.modrinth_pack(files={"../evil.jar": b"x"})
        with self.assertRaises(inst.InstallError):
            inst.install(self.env(), self.dest)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "evil.jar")))

    def test_disallowed_download_host(self):
        inst.host_allowed = self._saved[2]
        self.modrinth_pack()
        with self.assertRaises(inst.InstallError) as c:
            inst.install(self.env(), self.dest)
        self.assertIn("not an allowed host", str(c.exception))

    def test_client_only_skipped(self):
        idx = self.modrinth_pack(overrides={"overrides/fabric-server-launch.jar": "l"})
        idx["files"].append({"path": "mods/client.jar", "hashes": {"sha512": "0"}, "env": {"server": "unsupported"}, "downloads": []})
        data = zipbytes({"modrinth.index.json": json.dumps(idx), "overrides/fabric-server-launch.jar": "l"})
        self.mock.routes["/cdn/pack.mrpack"] = (200, data)
        self.mock.routes["/v2/project/mypack/version"][1][0]["files"][0]["hashes"]["sha512"] = sha(data)
        inst.install(self.env(), self.dest)
        self.assertFalse(os.path.exists(os.path.join(self.dest, "mods", "client.jar")))

    def test_reinstall_keeps_owner_data_and_replaces_mods(self):
        self.modrinth_pack(files={"mods/a.jar": b"AAA", "config/c.toml": b"pack default"},
                           overrides={"overrides/fabric-server-launch.jar": "l", "overrides/server.properties": "server-port=1"})
        inst.install(self.env(), self.dest)
        open(os.path.join(self.dest, "config", "c.toml"), "wb").write(b"owner edit")
        open(os.path.join(self.dest, "server.properties"), "wb").write(b"motd=mine")
        os.makedirs(os.path.join(self.dest, "world"))
        open(os.path.join(self.dest, "world", "level.dat"), "wb").write(b"WORLD")
        open(os.path.join(self.dest, "mods", "manual.jar"), "wb").write(b"owner's own mod")
        self.modrinth_pack(files={"mods/b.jar": b"BBB"}, overrides={"overrides/fabric-server-launch.jar": "l"})
        inst.install(self.env(), self.dest)
        self.assertFalse(os.path.exists(os.path.join(self.dest, "mods", "a.jar")), "mod from the previous install removed")
        self.assertEqual(self.read("mods/b.jar"), b"BBB")
        self.assertEqual(self.read("mods/manual.jar"), b"owner's own mod", "files the installer did not put there are untouched")
        self.assertEqual(self.read("config/c.toml"), b"owner edit")
        self.assertEqual(self.read("server.properties"), b"motd=mine")
        self.assertEqual(self.read("world/level.dat"), b"WORLD")

    def test_probe(self):
        self.modrinth_pack(deps={"minecraft": "1.21.1", "neoforge": "21.1.77"})
        out = inst.probe(self.env())
        self.assertEqual((out["minecraft"], out["loader"], out["loader_version"], out["java"], out["mods"]), ("1.21.1", "neoforge", "21.1.77", "java_21", 1))

    def test_unknown_project(self):
        with self.assertRaises(inst.InstallError) as c:
            inst.install(self.env(MODPACK_ID="nope"), self.dest)
        self.assertIn("not found", str(c.exception))

    def test_pinned_version_by_number(self):
        self.modrinth_pack(overrides={"overrides/fabric-server-launch.jar": "l"})
        inst.install(self.env(MODPACK_VERSION="1.0"), self.dest)
        with self.assertRaises(inst.InstallError):
            inst.install(self.env(MODPACK_VERSION="9.9"), self.dest + "2")


class TestCurseForge(Base):
    def setUp(self):
        super().setUp()
        self.mock.routes["/v1/mods/search"] = (200, {"data": [{"id": 111, "slug": "mypack", "name": "My Pack"}]})

    def cf_env(self, **kw):
        return {"MODPACK_SOURCE": "curseforge", "MODPACK_ID": "mypack", "CURSEFORGE_API_KEY": "KEYSECRET", **kw}

    def file(self, fid, name, data, **kw):
        self.mock.routes["/cdn/" + name] = (200, data)
        return {"id": fid, "displayName": name, "fileName": name, "fileDate": "2026-01-01", "gameVersions": ["1.20.1", "Forge"],
                "downloadUrl": self.mock.base + "/cdn/" + name, "hashes": [{"value": sha(data, "sha1"), "algo": 1}], **kw}

    def test_server_pack(self):
        server = zipbytes({"pack/libraries/net/minecraftforge/forge/1.20.1-47.4.0/unix_args.txt": "args", "pack/mods/a.jar": "1", "pack/run.sh":
                           "java @libraries/net/minecraftforge/forge/1.20.1-47.4.0/unix_args.txt"})
        sp = self.file(2, "server.zip", server)
        client = self.file(1, "client.zip", b"unused", serverPackFileId=2)
        self.mock.routes["/v1/mods/111/files"] = (200, {"data": [client]})
        self.mock.routes["/v1/mods/111/files/2"] = (200, {"data": sp})
        inst.install(self.cf_env(), self.dest)
        self.assertEqual(self.read("launch.args").strip(), b"@libraries/net/minecraftforge/forge/1.20.1-47.4.0/unix_args.txt")
        self.assertEqual(self.read("mods/a.jar"), b"1")
        has_key = lambda h: any(k.lower() == "x-api-key" for k in h)
        cdn = [h for p, h in self.mock.seen if p.startswith("/cdn/")]
        api = [h for p, h in self.mock.seen if not p.startswith("/cdn/")]
        self.assertTrue(cdn and not any(has_key(h) for h in cdn), "the API key is never sent to the download host")
        self.assertTrue(api and all(has_key(h) for h in api), "while every API call carries it")

    def test_loader_version_override(self):
        server = zipbytes({"pack/mods/a.jar": "1"})
        sp = self.file(2, "server.zip", server, gameVersions=["1.21.1", "NeoForge"])
        client = self.file(1, "client.zip", b"unused", serverPackFileId=2, gameVersions=["1.21.1", "NeoForge"])
        self.mock.routes["/v1/mods/111/files"] = (200, {"data": [client]})
        self.mock.routes["/v1/mods/111/files/2"] = (200, {"data": sp})
        seen = []
        orig = inst.install_loader
        inst.install_loader = lambda pack, dest, work: (seen.append(pack.loader_version), (_ for _ in ()).throw(inst.InstallError("stop")))[1]
        try:
            with self.assertRaises(inst.InstallError):
                inst.install(self.cf_env(LOADER_VERSION=" 21.1.259 "), self.dest)
        finally:
            inst.install_loader = orig
        self.assertEqual(seen, ["21.1.259"])

    def test_manifest_pack(self):
        m1 = self.file(11, "m1.jar", b"M1")
        m2 = self.file(12, "client.jar", b"C", gameVersions=["1.20.1", "Client"])
        manifest = {"minecraft": {"version": "1.20.1", "modLoaders": [{"id": "fabric-0.15.0", "primary": True}]}, "overrides": "overrides",
                    "files": [{"projectID": 5, "fileID": 11}, {"projectID": 6, "fileID": 12}]}
        client = self.file(1, "client.zip", zipbytes({"manifest.json": json.dumps(manifest), "overrides/fabric-server-launch.jar": "launcher",
                                                      "overrides/config/x.toml": "x"}))
        self.mock.routes["/v1/mods/111/files"] = (200, {"data": [client]})
        self.mock.routes["/v1/mods/5/files/11"] = (200, {"data": m1})
        self.mock.routes["/v1/mods/6/files/12"] = (200, {"data": m2})
        inst.install(self.cf_env(), self.dest)
        self.assertEqual(self.read("mods/m1.jar"), b"M1")
        self.assertFalse(os.path.exists(os.path.join(self.dest, "mods", "client.jar")), "client-only mod skipped")
        self.assertEqual(self.read("config/x.toml"), b"x")

    def test_blocked_mod_fails_clearly(self):
        m = self.file(11, "m1.jar", b"M1")
        m["downloadUrl"] = None
        manifest = {"minecraft": {"version": "1.20.1", "modLoaders": []}, "files": [{"projectID": 5, "fileID": 11}]}
        client = self.file(1, "client.zip", zipbytes({"manifest.json": json.dumps(manifest)}))
        self.mock.routes["/v1/mods/111/files"] = (200, {"data": [client]})
        self.mock.routes["/v1/mods/5/files/11"] = (200, {"data": m})
        with self.assertRaises(inst.InstallError) as c:
            inst.install(self.cf_env(), self.dest)
        self.assertIn("author opt-out", str(c.exception))

    def test_key_required(self):
        with self.assertRaises(inst.InstallError) as c:
            inst.install(self.cf_env(CURSEFORGE_API_KEY=""), self.dest)
        self.assertIn("API key", str(c.exception))

    def test_probe_is_metadata_only(self):
        client = self.file(1, "client.zip", b"x", serverPackFileId=None)
        self.mock.routes["/v1/mods/111/files"] = (200, {"data": [client]})
        out = inst.probe(self.cf_env())
        self.assertEqual((out["minecraft"], out["loader"], out["java"]), ("1.20.1", "forge", "java_17"))
        self.assertFalse([p for p, _ in self.mock.seen if p.startswith("/cdn/")], "probe downloads nothing")

    def test_key_never_logged(self):
        out = io.StringIO()
        old, sys.stdout = sys.stdout, out
        try:
            try:
                inst.install(self.cf_env(MODPACK_ID="missing"), self.dest)
            except inst.InstallError as e:
                print(str(e))
        finally:
            sys.stdout = old
        self.assertNotIn("KEYSECRET", out.getvalue())


class TestUrlSource(Base):
    def test_requires_https(self):
        with self.assertRaises(inst.InstallError):
            inst.install({"MODPACK_SOURCE": "url", "MODPACK_ID": "http://example.org/p.zip"}, self.dest)

    def test_private_address_refused(self):
        inst.public_host = self._saved[4]
        with self.assertRaises(inst.InstallError) as c:
            inst.fetch("https://127.0.0.1/p.zip", os.path.join(self.tmp, "p"), public_only=True)
        self.assertIn("public address", str(c.exception))


if __name__ == "__main__":
    unittest.main(verbosity=1)

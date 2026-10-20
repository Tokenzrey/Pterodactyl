#!/usr/bin/env python3
"""Offline tests for lib/games.py against a stateful mock of the Panel Application API (and a mock Modrinth for the probe)."""
import contextlib
import http.server
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_installer as ti   # noqa: E402  (Mock, zipbytes, sha, inst)

spec = importlib.util.spec_from_file_location("games", os.path.join(HERE, "..", "lib", "games.py"))
games = importlib.util.module_from_spec(spec)
spec.loader.exec_module(games)

EGG = "Minecraft Modpack (CurseForge / Modrinth)"


class MockPanel:
    def __init__(self):
        self.calls, self.fail_status = [], None
        self.launch_present = True
        self.eggs = [{"id": 1, "name": EGG, "features": ["eula", "java_version"], "startup": "java ... $(cat launch.args) nogui",
                      "docker_images": {"Java 21": "ghcr.io/pterodactyl/yolks:java_21", "Java 17": "ghcr.io/pterodactyl/yolks:java_17"},
                      "vars": [("MODPACK_SOURCE", "modrinth"), ("MODPACK_ID", ""), ("MODPACK_VERSION", ""), ("MODPACK_MC_VERSION", ""),
                               ("JAVA_FLAGS", "-XX:+UseG1GC"), ("CURSEFORGE_API_KEY", "STORED-KEY")]},
                     {"id": 2, "name": "Paper-like without eula", "features": [], "startup": "", "docker_images": {}, "vars": []}]
        self.allocs = [{"id": 10, "ip": "127.0.0.1", "port": 25601, "assigned": True}, {"id": 11, "ip": "127.0.0.1", "port": 25602, "assigned": True},
                       {"id": 12, "ip": "0.0.0.0", "port": 25603, "assigned": True}, {"id": 13, "ip": "127.0.0.1", "port": 25604, "assigned": True}]
        self.servers = [self.server(1, "My Survival!", 1, 10, 2048), self.server(2, "Web thing", 2, 11, 512),
                        self.server(3, "Exposed", 1, 12, 512), self.server(4, "Napping", 1, 13, 512, suspended=True)]
        self.users = [{"id": 7, "email": "ops@mytest.dev"}]
        mp = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def handle_any(self, method):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"null")
                path = self.path.split("?")[0]
                mp.calls.append((method, path, body))
                if self.headers.get("Authorization") != "Bearer " + os.environ.get("MOCK_PANEL_KEY", "ptla_testkey"):
                    return self.send(401, {"errors": []})
                code, obj = mp.route(method, path, body)
                self.send(code, obj)

            def send(self, code, obj):
                b = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                self.handle_any("GET")

            def do_POST(self):
                self.handle_any("POST")

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def server(self, sid, name, egg, alloc, mem, suspended=False):
        return {"id": sid, "uuid": f"uuid-{sid}", "name": name, "egg": egg, "node": 1, "allocation": alloc, "suspended": suspended,
                "limits": {"memory": mem}, "status": None}

    @staticmethod
    def page(items):
        return {"data": items, "meta": {"pagination": {"total_pages": 1, "current_page": 1}}}

    def route(self, method, path, body):
        if path == "/api/application/eggs":
            return 200, self.page([{"attributes": {k: e[k] for k in ("id", "name", "features")}} for e in self.eggs])
        m = re.fullmatch(r"/api/application/eggs/(\d+)", path)
        if m:
            e = next(x for x in self.eggs if x["id"] == int(m.group(1)))
            vs = [{"attributes": {"env_variable": k, "default_value": v}} for k, v in e["vars"]]
            return 200, {"attributes": {**{k: e[k] for k in ("id", "name", "startup", "docker_images")}, "relationships": {"variables": {"data": vs}}}}
        if path == "/api/application/servers" and method == "GET":
            data = []
            for s in self.servers:
                al = [{"attributes": a} for a in self.allocs if a["id"] == s["allocation"]]
                data.append({"attributes": {**s, "relationships": {"allocations": {"data": al}}}})
            return 200, self.page(data)
        if path == "/api/application/servers" and method == "POST":
            sid = len(self.servers) + 1
            s = self.server(sid, body["name"], body["egg"], body["allocation"]["default"], body["limits"]["memory"])
            s["status"] = "installing"
            s["polls"] = 0
            self.servers.append(s)
            for a in self.allocs:
                if a["id"] == s["allocation"]:
                    a["assigned"] = True
            return 201, {"attributes": {"id": sid, "uuid": f"uuid-{sid}"}}
        m = re.fullmatch(r"/api/application/servers/(\d+)", path)
        if m:
            s = next(x for x in self.servers if x["id"] == int(m.group(1)))
            s["polls"] = s.get("polls", 9) + 1
            if s.get("polls", 9) >= 2:
                s["status"] = self.fail_status
                s["installed"] = 1 if self.fail_status is None else 0   # Wings reports success: installed flips to 1
            return 200, {"attributes": {"id": s["id"], "status": s["status"], "container": {"installed": s.get("installed", 0)}}}
        if path == "/api/application/nodes/1":
            return 200, {"attributes": {"id": 1, "memory": 10240, "memory_overallocate": 0}}
        if path == "/api/application/nodes/1/allocations" and method == "GET":
            return 200, self.page([{"attributes": a} for a in self.allocs])
        if path == "/api/application/nodes/1/allocations" and method == "POST":
            for p in body["ports"]:
                self.allocs.append({"id": 100 + int(p), "ip": body["ip"], "port": int(p), "assigned": False})
            return 204, {}
        if path == "/api/application/users":
            return 200, self.page([{"attributes": u} for u in self.users])
        if re.fullmatch(r"/api/client/servers/[^/]+/files/contents", path):
            return (200, b"ok") if self.launch_present else (404, {"errors": []})
        return 404, {}

    def close(self):
        self.srv.shutdown()


class Base(unittest.TestCase):
    def setUp(self):
        self.panel = MockPanel()
        self.tmp = tempfile.mkdtemp(prefix="tg-")
        self.routes = os.path.join(self.tmp, "mc-router", "routes.json")
        self.env_saved = dict(os.environ)
        os.environ.update({"PANEL_API_URL": self.panel.url, "PANEL_API_KEY": "ptla_testkey", "GAMES_DOMAIN": "mc.mytest.dev", "ROUTES_FILE": self.routes,
                           "GAMES_NODE_ID": "1", "GAMES_BACKEND_FIRST": "25600", "GAMES_BACKEND_LAST": "25699", "ADMIN_EMAIL": "ops@mytest.dev",
                           "GAMES_PORT": "25565", "CURSEFORGE_API_KEY": ""})

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_saved)
        self.panel.close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cmd(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        old = sys.argv
        sys.argv = ["games.py", *argv]
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = games.main()
        finally:
            sys.argv = old
        return rc, out.getvalue(), err.getvalue()

    def read_routes(self):
        with open(self.routes) as f:
            return json.load(f)["mappings"]


class TestSync(Base):
    def test_routes_only_loopback_minecraft_servers(self):
        rc, out, err = self.run_cmd("sync")
        self.assertEqual(rc, 0)
        self.assertEqual(self.read_routes(), {"my-survival.mc.mytest.dev": "127.0.0.1:25601"})
        self.assertIn("CHANGED", out)
        self.assertIn("Exposed: allocation is 0.0.0.0:25603", err)
        self.assertIn("Napping: suspended", err)
        self.assertNotIn("Web thing", out + err, "non-Minecraft eggs are ignored silently")

    def test_idempotent(self):
        self.run_cmd("sync")
        mtime = os.stat(self.routes).st_mtime_ns
        rc, out, _ = self.run_cmd("sync", "--quiet")
        self.assertEqual((rc, out), (0, ""))
        self.assertEqual(os.stat(self.routes).st_mtime_ns, mtime, "an unchanged table is not rewritten")

    def test_new_server_appears_and_removed_server_disappears(self):
        self.run_cmd("sync")
        self.panel.servers.append(self.panel.server(9, "Creative", 1, 10, 1024))
        self.panel.servers[-1]["allocation"] = 10
        self.panel.servers = [s for s in self.panel.servers if s["name"] != "My Survival!"]
        rc, out, _ = self.run_cmd("sync")
        self.assertEqual(self.read_routes(), {"creative.mc.mytest.dev": "127.0.0.1:25601"})
        self.assertIn("CHANGED", out)

    def test_collision_refuses_and_keeps_file(self):
        self.run_cmd("sync")
        before = open(self.routes).read()
        self.panel.servers.append(self.panel.server(9, "my survival", 1, 11, 1024))
        rc, _, err = self.run_cmd("sync")
        self.assertEqual(rc, 3)
        self.assertIn("would both be my-survival.mc.mytest.dev", err)
        self.assertEqual(open(self.routes).read(), before)

    def test_panel_down_keeps_file(self):
        self.run_cmd("sync")
        before = open(self.routes).read()
        self.panel.close()
        os.environ["PANEL_API_URL"] = "http://127.0.0.1:1"
        rc, _, err = self.run_cmd("sync")
        self.assertEqual(rc, 2)
        self.assertIn("cannot reach the Panel", err)
        self.assertEqual(open(self.routes).read(), before, "an outage must not wipe the routing table")

    def test_wrong_key(self):
        os.environ["PANEL_API_KEY"] = "ptla_wrong"
        rc, _, err = self.run_cmd("sync")
        self.assertEqual(rc, 2)
        self.assertIn("rejected the API key", err)
        self.assertFalse(os.path.exists(self.routes))
        self.assertNotIn("ptla_wrong", err)

    def test_slugify(self):
        self.assertEqual(games.slugify("My Survival!"), "my-survival")
        self.assertEqual(games.slugify("  --A__b--  "), "a-b")
        with self.assertRaises(games.Fail):
            games.slugify("!!!")


class TestCreate(Base):
    def setUp(self):
        super().setUp()
        self.mod = ti.Mock()
        self.inst = ti.inst
        self.saved = (self.inst.MODRINTH_BASE, self.inst.host_allowed, self.inst.mojang_java_major, self.inst.public_host)
        self.inst.MODRINTH_BASE = self.mod.base
        self.inst.host_allowed = lambda url, hosts: True
        self.inst.mojang_java_major = lambda mc: None
        games._INSTALLER = self.inst
        index = {"formatVersion": 1, "name": "T", "versionId": "1", "dependencies": {"minecraft": "1.21.1", "fabric-loader": "0.16.0"},
                 "files": [{"path": "mods/a.jar", "hashes": {"sha512": "0"}, "env": {"server": "required"}, "downloads": []}] * 3}
        data = ti.zipbytes({"modrinth.index.json": json.dumps(index)})
        self.mod.routes["/cdn/p.mrpack"] = (200, data)
        self.mod.routes["/v2/project/cool-pack/version"] = (200, [{"id": "v", "version_number": "2.0", "name": "Cool 2.0", "version_type": "release",
                                                                   "game_versions": ["1.21.1"], "files": [{"primary": True, "filename": "p.mrpack",
                                                                   "url": self.mod.base + "/cdn/p.mrpack", "hashes": {"sha512": ti.sha(data)}}]}])

    def tearDown(self):
        self.inst.MODRINTH_BASE, self.inst.host_allowed, self.inst.mojang_java_major, self.inst.public_host = self.saved
        games._INSTALLER = None
        self.mod.close()
        super().tearDown()

    def create(self, *extra, apply=False):
        args = ["create", "--name", "Fresh World", "--source", "modrinth", "--pack", "cool-pack", "--no-wait", *extra]
        return self.run_cmd(*args, *(["--apply"] if apply else []))

    def test_plan_changes_nothing(self):
        rc, out, _ = self.create()
        self.assertEqual(rc, 0)
        self.assertIn("fresh-world.mc.mytest.dev", out)
        self.assertIn("Minecraft 1.21.1", out)
        self.assertIn("java_21", out)
        self.assertIn("plan only", out)
        self.assertFalse([c for c in self.panel.calls if c[0] == "POST"], "a plan must not create anything")

    def test_apply_creates_allocation_server_and_route(self):
        rc, out, err = self.create(apply=True)
        self.assertEqual(rc, 0, err)
        posts = [c for c in self.panel.calls if c[0] == "POST"]
        self.assertEqual([p[1] for p in posts], ["/api/application/nodes/1/allocations", "/api/application/servers"])
        self.assertEqual(posts[0][2], {"ip": "127.0.0.1", "ports": ["25600"]}, "first free port of the backend range, loopback only")
        body = posts[1][2]
        self.assertEqual((body["egg"], body["user"], body["docker_image"]), (1, 7, "ghcr.io/pterodactyl/yolks:java_21"))
        self.assertEqual(body["environment"]["MODPACK_ID"], "cool-pack")
        self.assertEqual(body["environment"]["MODPACK_SOURCE"], "modrinth")
        self.assertFalse(body["start_on_completion"], "never auto-start: the EULA needs the owner's consent")
        self.assertEqual(body["limits"]["memory"], 4096)
        self.assertEqual(body["limits"]["swap"], 0)
        self.assertEqual(self.read_routes()["fresh-world.mc.mytest.dev"], "127.0.0.1:25600")
        self.assertNotIn("STORED-KEY", out + err, "the CurseForge key is never printed")

    def test_waits_for_install_and_reports_failure(self):
        self.panel.fail_status = "install_failed"
        old_sleep = games.time.sleep
        games.time.sleep = lambda s: None
        try:
            rc, _, err = self.run_cmd("create", "--name", "Fresh World", "--source", "modrinth", "--pack", "cool-pack", "--apply")
        finally:
            games.time.sleep = old_sleep
        self.assertEqual(rc, 1)
        self.assertIn("install failed", err)

    def test_refusals(self):
        rc, _, err = self.run_cmd("create", "--name", "My Survival!", "--source", "modrinth", "--pack", "cool-pack")
        self.assertEqual((rc, "already exists" in err), (3, True))
        rc, _, err = self.create("--memory", "9000")
        self.assertEqual(rc, 3)
        self.assertIn("not enough node memory", err)
        rc, _, err = self.create("--port", "30000")
        self.assertEqual(rc, 3)
        self.assertIn("backend range", err)
        rc, _, err = self.create("--port", "25601")
        self.assertEqual(rc, 3)
        self.assertIn("already assigned", err)
        rc, _, err = self.create("--owner", "nobody@x.dev")
        self.assertEqual(rc, 3)
        self.panel.eggs = self.panel.eggs[1:]
        rc, _, err = self.create()
        self.assertEqual(rc, 3)
        self.assertIn("./ptero egg install", err)

    def test_unknown_pack(self):
        rc, _, err = self.run_cmd("create", "--name", "X", "--source", "modrinth", "--pack", "no-such-pack")
        self.assertEqual(rc, 3)
        self.assertIn("cannot read the pack", err)

    def test_egg_name_matches_the_template(self):
        with open(os.path.join(HERE, "..", "eggs", "modpack-installer", "egg.template.json")) as f:
            self.assertEqual(json.load(f)["name"], games.EGG_NAME)


class TestInstallVerification(Base):
    def setUp(self):
        super().setUp()
        self.mod = ti.Mock()
        self.inst = ti.inst
        self.saved = (self.inst.MODRINTH_BASE, self.inst.host_allowed, self.inst.mojang_java_major, self.inst.public_host)
        self.inst.MODRINTH_BASE = self.mod.base
        self.inst.host_allowed = lambda url, hosts: True
        self.inst.mojang_java_major = lambda mc: None
        games._INSTALLER = self.inst
        index = {"formatVersion": 1, "name": "T", "versionId": "1", "dependencies": {"minecraft": "1.21.1", "fabric-loader": "0.16.0"},
                 "files": []}
        data = ti.zipbytes({"modrinth.index.json": json.dumps(index)})
        self.mod.routes["/cdn/p.mrpack"] = (200, data)
        self.mod.routes["/v2/project/cool-pack/version"] = (200, [{"id": "v", "version_number": "2.0", "name": "Cool 2.0", "version_type": "release",
            "game_versions": ["1.21.1"], "files": [{"primary": True, "filename": "p.mrpack", "url": self.mod.base + "/cdn/p.mrpack",
                                                    "hashes": {"sha512": ti.sha(data)}}]}])
        os.environ["PANEL_CLIENT_KEY"] = "ptla_testkey"   # the mock accepts one bearer token for both APIs
        self._sleep = games.time.sleep
        games.time.sleep = lambda seconds: None

    def tearDown(self):
        self.inst.MODRINTH_BASE, self.inst.host_allowed, self.inst.mojang_java_major, self.inst.public_host = self.saved
        games._INSTALLER = None
        os.environ.pop("PANEL_CLIENT_KEY", None)
        games.time.sleep = self._sleep
        self.mod.close()
        super().tearDown()

    def test_file_check_true_false_and_rejected(self):
        self.assertTrue(games.panel_file_exists(self.panel.url, "ptla_testkey", "uuid-1", "launch.args"))
        self.panel.launch_present = False
        self.assertFalse(games.panel_file_exists(self.panel.url, "ptla_testkey", "uuid-1", "launch.args"))
        with self.assertRaises(games.Fail) as c:
            games.panel_file_exists(self.panel.url, "ptla_wrong", "uuid-1", "launch.args")
        self.assertEqual(c.exception.code, 2)

    def test_success_is_verified_when_launch_file_exists(self):
        rc, out, err = self.run_cmd("create", "--name", "Fresh", "--source", "modrinth", "--pack", "cool-pack", "--apply")
        self.assertEqual(rc, 0, err)
        self.assertIn("verified: launch.args is in place", out)

    def test_finished_but_no_launch_file_is_a_failure(self):
        self.panel.launch_present = False
        rc, _, err = self.run_cmd("create", "--name", "Fresh", "--source", "modrinth", "--pack", "cool-pack", "--apply")
        self.assertEqual(rc, 1)
        self.assertIn("launch.args is missing", err)

    def test_without_client_key_it_says_so(self):
        os.environ.pop("PANEL_CLIENT_KEY", None)
        rc, out, err = self.run_cmd("create", "--name", "Fresh", "--source", "modrinth", "--pack", "cool-pack", "--apply")
        self.assertEqual(rc, 0, err)
        self.assertIn("warning: not verified", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)

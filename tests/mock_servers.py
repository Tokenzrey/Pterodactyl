#!/usr/bin/env python3
"""Start a mock Panel API and a mock Modrinth for shell tests; write {"panel": port, "modrinth": port} to argv[1] and serve until killed."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault("MOCK_PANEL_KEY", "ptla_" + "k" * 24)
import test_games as tg   # noqa: E402
import test_installer as ti   # noqa: E402

panel = tg.MockPanel()
mod = ti.Mock()
index = {"formatVersion": 1, "name": "T", "versionId": "1", "dependencies": {"minecraft": "1.21.1", "fabric-loader": "0.16.0"},
         "files": [{"path": "mods/a.jar", "hashes": {"sha512": "0"}, "env": {"server": "required"}, "downloads": []}] * 3}
data = ti.zipbytes({"modrinth.index.json": json.dumps(index)})
mod.routes["/cdn/p.mrpack"] = (200, data)
mod.routes["/v2/project/cool-pack/version"] = (200, [{"id": "v", "version_number": "2.0", "name": "Cool 2.0", "version_type": "release", "game_versions": ["1.21.1"],
                                                      "files": [{"primary": True, "filename": "p.mrpack", "url": mod.base + "/cdn/p.mrpack", "hashes": {"sha512": ti.sha(data)}}]}])
with open(sys.argv[1], "w") as f:
    json.dump({"panel": panel.srv.server_address[1], "modrinth": mod.srv.server_address[1], "key": os.environ["MOCK_PANEL_KEY"]}, f)
import time
while True:
    time.sleep(1)

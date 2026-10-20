#!/usr/bin/env bash
# lib/games.py (hostname table from the Panel API, server creation) against a mock Panel; the generated egg
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1

echo "games.py unit tests (mock Panel Application API + mock Modrinth)"
out=$(python3 -B tests/test_games.py 2>&1); rc=$?
printf '%s\n' "$out" | tail -n 12 | sed 's/^/       /'
n=$(grep -oE 'Ran [0-9]+ tests' <<<"$out" | grep -oE '[0-9]+')
assert_eq 0 "$rc" "python unittest suite passes (${n:-0} tests)"

echo "the egg"
python3 -B lib/egg_build.py --check; assert_eq 0 "$?" "eggs/modpack-installer/modpack-installer.egg.json is exactly what the sources build"
python3 - <<'PY' && pass "egg JSON is importable by the Panel's rules" || fail "egg JSON is importable by the Panel's rules"
import json, re, sys
e = json.load(open("eggs/modpack-installer/modpack-installer.egg.json"))
assert e["meta"]["version"] == "PTDL_v2"
assert re.fullmatch(r"[^@\s]+@[^@\s]+\.[A-Za-z]+", e["author"]), "the Panel validates the egg author as an e-mail address (found by importing into a real Panel)"
for k in ("name", "author", "startup", "docker_images", "scripts", "variables", "config"):
    assert k in e, k
inst = e["scripts"]["installation"]
assert inst["entrypoint"] == "bash" and "@sha256:" in inst["container"], "install container is pinned by digest"
assert e["scripts"]["installation"]["script"].count("PTERO_INSTALLER_EOF") == 2, "one heredoc"
envs = [v["env_variable"] for v in e["variables"]]
assert len(envs) == len(set(envs))
for v in e["variables"]:
    assert isinstance(v["default_value"], str) and isinstance(v["rules"], str)
    assert isinstance(v["user_viewable"], bool) and isinstance(v["user_editable"], bool)
    assert re.fullmatch(r"[A-Z_]+", v["env_variable"])
key = next(v for v in e["variables"] if v["env_variable"] == "CURSEFORGE_API_KEY")
assert key["user_viewable"] is False and key["user_editable"] is False and key["default_value"] == "", "key hidden from owners, empty in the repo"
for needed in ("{{JAVA_FLAGS}}", "launch.args"):
    assert needed in e["startup"], needed
assert "eula" in e["features"]
assert "eula=true" not in e["scripts"]["installation"]["script"], "the egg never accepts the EULA"
PY
bash -n <(python3 -c "import json;print(json.load(open('eggs/modpack-installer/modpack-installer.egg.json'))['scripts']['installation']['script'])") 2>/dev/null \
    && pass "the embedded install script is valid bash" || fail "the embedded install script is valid bash"
# the python embedded in the egg is byte-identical to installer.py
python3 - <<'PY' && pass "installer.py is embedded verbatim" || fail "installer.py is embedded verbatim"
import json
e = json.load(open("eggs/modpack-installer/modpack-installer.egg.json"))
s = e["scripts"]["installation"]["script"]
body = s.split("<<'PTERO_INSTALLER_EOF'\n", 1)[1].split("\nPTERO_INSTALLER_EOF\n", 1)[0]
assert body == open("eggs/modpack-installer/installer.py").read().rstrip("\n")
PY

finish

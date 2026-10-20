#!/usr/bin/env python3
"""Assemble eggs/modpack-installer/modpack-installer.egg.json from its sources (deterministic).

  egg_build.py            write the egg file
  egg_build.py --check    exit 1 if the committed egg is not what the sources produce
  egg_build.py --key-from-env NAME --out FILE   write a copy with CURSEFORGE_API_KEY's default taken from $NAME (for import only)

The install script embeds installer.py verbatim, so the Panel needs no external download at install time.
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "eggs", "modpack-installer")
OUT = os.path.join(SRC, "modpack-installer.egg.json")
DELIM = "PTERO_INSTALLER_EOF"

WRAPPER = """#!/bin/bash
# Generated from eggs/modpack-installer/installer.py by lib/egg_build.py. Do not edit here.
set -u
export DEBIAN_FRONTEND=noninteractive
if ! command -v python3 >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 ca-certificates >/dev/null \\
    || {{ echo "[modpack] ERROR: cannot install python3 in the install container"; exit 1; }}
fi
mkdir -p /mnt/server
cat > /tmp/installer.py <<'{delim}'
{body}
{delim}
exec python3 /tmp/installer.py --dest /mnt/server
"""


def read_versions():
    env = {}
    with open(os.path.join(ROOT, "config", "versions.env")) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    return env


def build():
    with open(os.path.join(SRC, "installer.py")) as f:
        body = f.read().rstrip("\n")
    if any(line.strip() == DELIM for line in body.splitlines()):
        raise SystemExit("installer.py contains the heredoc delimiter")
    with open(os.path.join(SRC, "egg.template.json")) as f:
        egg = json.load(f)
    env = read_versions()
    egg["scripts"]["installation"]["script"] = WRAPPER.format(delim=DELIM, body=body)
    egg["scripts"]["installation"]["container"] = env["INSTALLER_IMAGE"]
    return egg


def dump(egg):
    return json.dumps(egg, indent=4, ensure_ascii=False) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--key-from-env")
    ap.add_argument("--out")
    a = ap.parse_args()
    egg = build()
    if a.check:
        try:
            with open(OUT) as f:
                same = f.read() == dump(egg)
        except OSError:
            same = False
        if not same:
            print("modpack-installer.egg.json is out of date: run ./ptero egg build", file=sys.stderr)
        return 0 if same else 1
    if a.key_from_env:
        key = os.environ.get(a.key_from_env, "")
        for v in egg["variables"]:
            if v["env_variable"] == "CURSEFORGE_API_KEY":
                v["default_value"] = key
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(dump(egg))
        return 0
    with open(OUT, "w") as f:
        f.write(dump(egg))
    print(f"wrote {os.path.relpath(OUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

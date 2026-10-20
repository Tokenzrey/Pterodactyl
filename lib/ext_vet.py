#!/usr/bin/env python3
"""Look inside a Panel extension package (.zip / .pteroext) without installing it. Standard library only.

  ext_vet.py info FILE     JSON: id, type, version, name, sha256 (read from extension.json)
  ext_vet.py vet  FILE     the same plus a scan of the PHP for calls that deserve a human look; exit 1 if any are found

The scan is a tripwire, not a proof of safety: it flags code execution (exec, shell_exec, system, passthru, proc_open, eval),
outbound HTTP from PHP (Http::, curl_init, file_get_contents of a URL) and unserialize(). Read what it reports.
"""
import hashlib
import json
import re
import sys
import zipfile

SUSPICIOUS = [
    (r"\b(shell_exec|passthru|proc_open|popen|pcntl_exec)\s*\(", "runs system commands"),
    (r"\b(exec|system)\s*\(", "runs system commands"),
    (r"\beval\s*\(", "evaluates code"),
    (r"\bunserialize\s*\(", "unserialize (object injection risk)"),
    (r"\bHttp::|\bcurl_init\s*\(|\bGuzzle|file_get_contents\s*\(\s*['\"]?https?:", "outbound HTTP from PHP"),
    (r"\bbase64_decode\s*\(", "decodes opaque data (often hides code)"),
]


def read(path):
    with open(path, "rb") as f:
        data = f.read()
    z = zipfile.ZipFile(path)
    manifest = json.loads(z.read("extension.json"))
    return data, z, manifest


def info(path):
    data, _, m = read(path)
    return {"id": m.get("id"), "type": m.get("type", "extension"), "version": m.get("version"), "name": m.get("name"),
            "sha256": hashlib.sha256(data).hexdigest()}


def vet(path):
    _, z, _ = read(path)
    findings = []
    for name in z.namelist():
        if not name.endswith(".php"):
            continue
        text = z.read(name).decode("utf-8", "replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for pattern, why in SUSPICIOUS:
                if re.search(pattern, line):
                    findings.append(f"{name}:{lineno}: {why}: {line.strip()[:120]}")
    return findings


def main(argv):
    if len(argv) != 3 or argv[1] not in ("info", "vet"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        i = info(argv[2])
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as e:
        print(f"not a Panel extension package: {e}", file=sys.stderr)
        return 2
    if argv[1] == "info":
        print(json.dumps(i))
        return 0
    print(json.dumps(i))
    findings = vet(argv[2])
    for f in findings:
        print("REVIEW", f)
    print(f"{len(findings)} item(s) to review" if findings else "no suspicious PHP calls found")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

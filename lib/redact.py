#!/usr/bin/env python3
"""stdin -> stdout, masking secrets. Secret *values* come from the files listed in
PTERO_REDACT_FILES (colon separated) so they never appear in a command line, plus generic token shapes."""
import os
import re
import sys

PATTERNS = [
    re.compile(r"eyJ[A-Za-z0-9_\-]{30,}[A-Za-z0-9_=\-]*"),          # Cloudflare tunnel token / JWT
    re.compile(r"\bptl[ac]_[A-Za-z0-9]{16,}"),                        # Panel API keys
    re.compile(r"(?i)(authorization:\s*bearer\s+)\S+"),
    re.compile(r"(?im)^(\s*(?:token|token_id|password|secret|app_key|hashids_salt)\s*[:=]\s*).+$"),
]


def main():
    secrets = []
    for path in filter(None, os.environ.get("PTERO_REDACT_FILES", "").split(":")):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                v = f.read().strip()
        except OSError:
            continue
        if len(v) >= 6:
            secrets.append(v)
    secrets.sort(key=len, reverse=True)
    for line in sys.stdin:
        for s in secrets:
            line = line.replace(s, "[REDACTED]")
        for p in PATTERNS:
            line = p.sub(lambda m: (m.group(1) if m.lastindex else "") + "[REDACTED]", line)
        sys.stdout.write(line)


if __name__ == "__main__":
    main()

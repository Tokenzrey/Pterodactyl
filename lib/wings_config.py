#!/usr/bin/env python3
"""Check and minimally patch a Wings config.yml (standard library only, no YAML parser).

The file is line-edited, never re-serialised, so everything the Panel wrote (token, uuid, docker
network, comments) is kept byte for byte except the few keys listed below.

  wings_config.py check FILE [--remote URL] [--port N]
  wings_config.py patch FILE --out OUT --port N --remote URL --origin URL [--host H] [--trusted-proxy IP] [--sftp-host H]

patch sets:   api.host, api.port, remote, system.sftp.bind_address, ensures allowed_origins has --origin,
              ensures api.trusted_proxies has --trusted-proxy.
Secrets (token, token_id) are never printed.
"""
import argparse
import json
import os
import re
import sys
import tempfile

TOP_RE = re.compile(r"^([A-Za-z_][\w-]*):(.*)$")


def json_to_yaml(obj, indent=0):
    """Block YAML from a JSON document (the Panel's /configuration endpoint). Strings use JSON quoting, which YAML accepts."""
    pad = " " * indent
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                out.append(f"{pad}{k}:")
                out += json_to_yaml(v, indent + 2)
            else:
                out.append(f"{pad}{k}: {scalar_yaml(v)}")
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                sub = json_to_yaml(item, indent + 2)
                out.append(f"{pad}- {sub[0].lstrip()}")
                out += sub[1:]
            else:
                out.append(f"{pad}- {scalar_yaml(item)}")
    return out


def scalar_yaml(v):
    if isinstance(v, dict):
        return "{}"
    if isinstance(v, list):
        return "[]"
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return json.dumps(v)
    return str(v)


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        text = f.read().replace("\r\n", "\n")
    if text.lstrip().startswith("{"):   # the Panel's JSON form of the same document
        return json_to_yaml(json.loads(text))
    return text.split("\n")


def render_path(keys, value, indent):
    """Lines that create the nested keys `keys` ending in `value` (already YAML-formatted)."""
    lines = []
    for depth, key in enumerate(keys[:-1]):
        lines.append(" " * (indent + 2 * depth) + f"{key}:")
    lines.append(" " * (indent + 2 * (len(keys) - 1)) + f"{keys[-1]}: {value}")
    return lines


def find_child(lines, start, end, key, indent):
    """Index of `key:` at exactly `indent` inside the block that starts at `start` (end is exclusive)."""
    pat = re.compile(r"^" + " " * indent + re.escape(key) + r":(\s|$)")
    for i in range(start + 1, end):
        if pat.match(lines[i]):
            return i
    return None


def set_path(lines, path, value):
    """Set a nested scalar, creating missing parent blocks. Existing keys change in place; missing ones are inserted as the
    last entries of their closest existing parent block, so nothing else in the file moves."""
    top = top_index(lines)
    if path[0] not in top:
        lines += render_path(path, value, 0)
        return "created"
    start, indent = top[path[0]], 0
    end = block_end(lines, start)
    for depth, key in enumerate(path[1:], 1):
        hit = find_child(lines, start, end, key, indent + 2)
        if hit is None:
            # a parent written inline (`docker: {}`) must become a block before children can hang under it
            if re.match(r"^[A-Za-z_][\w-]*:\s*\S", lines[start]):
                lines[start] = re.sub(r":.*$", ":", lines[start])
            lines[end:end] = render_path(path[depth:], value, indent + 2)
            return "created"
        start, indent = hit, indent + 2
        end = block_end(lines, start)
    if set_scalar(lines, start, path[-1], value):
        return "changed"
    return "same"


def unquote(v):
    v = v.split(" #")[0].strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def top_index(lines):
    """{key: line index} of top-level keys."""
    return {m.group(1): i for i, l in enumerate(lines) if (m := TOP_RE.match(l))}


def block_end(lines, start):
    """Index after the last line belonging to the top-level key at `start`."""
    i = start + 1
    while i < len(lines) and (not lines[i] or lines[i][0] in " \t#-"):
        i += 1
    # trailing blank lines belong to the gap, not to the block
    while i > start + 1 and not lines[i - 1].strip():
        i -= 1
    return i


def find_in_block(lines, start, end, key, min_indent=1):
    """First `key:` line inside [start+1, end) with the smallest indent. Returns (index, indent) or None."""
    best = None
    pat = re.compile(r"^(\s+)" + re.escape(key) + r":(.*)$")
    for i in range(start + 1, end):
        m = pat.match(lines[i])
        if m and len(m.group(1)) >= min_indent and (best is None or len(m.group(1)) < best[1]):
            best = (i, len(m.group(1)))
    return best


def find_path(lines, path):
    """Index of the line for a nested key such as ['system', 'sftp', 'bind_address'], or None."""
    top = top_index(lines)
    if path[0] not in top:
        return None
    start, end, indent = top[path[0]], block_end(lines, top[path[0]]), 0
    for key in path[1:]:
        hit = find_in_block(lines, start, end, key, indent + 1)
        if not hit:
            return None
        start, indent = hit
        end = start + 1   # the sub-block ends at the first following line that is not indented deeper
        while end < len(lines) and (not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) > indent):
            end += 1
    return start


def scalar_at(line, key):
    m = re.match(r"^\s*" + re.escape(key) + r":(.*)$", line)
    return unquote(m.group(1)) if m else None


def get_api(lines, key):
    top = top_index(lines)
    if "api" not in top:
        return None
    s = top["api"]
    hit = find_in_block(lines, s, block_end(lines, s), key)
    return scalar_at(lines[hit[0]], key) if hit else None


def get_ssl_enabled(lines):
    top = top_index(lines)
    if "api" not in top:
        return None
    s = top["api"]
    e = block_end(lines, s)
    ssl = find_in_block(lines, s, e, "ssl")
    if not ssl:
        return None
    # `ssl: {enabled: false}` inline form or a nested block
    inline = re.search(r"enabled:\s*(true|false)", lines[ssl[0]])
    if inline:
        return inline.group(1)
    for i in range(ssl[0] + 1, e):
        m = re.match(r"^(\s+)enabled:\s*(\S+)", lines[i])
        if m and len(m.group(1)) > ssl[1]:
            return m.group(2)
        if lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) <= ssl[1]:
            break
    return None


def list_items(lines, idx, indent):
    """(items, last_line_index, item_indent) for the YAML list owned by the key line at idx."""
    m = re.match(r"^\s*[\w-]+:\s*(.*)$", lines[idx])
    rest = m.group(1).split(" #")[0].strip()
    if rest.startswith("["):
        inner = rest.strip()[1:].rsplit("]", 1)[0]
        return [unquote(x) for x in inner.split(",") if x.strip()], idx, None
    items, last, item_indent = [], idx, None
    i = idx + 1
    while i < len(lines):
        mm = re.match(r"^(\s*)-\s+(.*)$", lines[i])
        if not mm or len(mm.group(1)) < indent:
            break
        items.append(unquote(mm.group(2)))
        last, item_indent = i, len(mm.group(1))
        i += 1
    return items, last, item_indent


def ensure_list_item(lines, idx, indent, item):
    items, last, item_indent = list_items(lines, idx, indent)
    if item in items:
        return False
    key_line = lines[idx]
    inline = re.match(r"^(\s*[\w-]+:)\s*\[", key_line)
    if inline:  # rewrite the inline list as a block list (top-level lists keep items flush left, like the Panel's output)
        pad = " " * (0 if indent == 0 else indent + 2)
        new = [inline.group(1)] + [f"{pad}- {x}" for x in items + [item]]
        lines[idx:idx + 1] = new
    else:
        pad = " " * (item_indent if item_indent is not None else indent + 2)
        lines.insert(last + 1, f"{pad}- {item}")
    return True


def set_scalar(lines, idx, key, value):
    m = re.match(r"^(\s*" + re.escape(key) + r":)\s*.*$", lines[idx])
    new = f"{m.group(1)} {value}"
    if lines[idx] == new:
        return False
    lines[idx] = new
    return True


def check(lines, remote=None, port=None):
    errors, warnings = [], []
    top = top_index(lines)
    for k in ("uuid", "token_id", "token", "api", "system", "remote"):
        if k not in top:
            errors.append(f"missing top-level key '{k}' (is this the file from Node -> Configuration?)")
    if errors:
        return errors, warnings
    for k in ("uuid", "token_id", "token"):
        v = unquote(TOP_RE.match(lines[top[k]]).group(2))
        if not v or v.lower() in ("changeme", "<token>", "your_token_here"):
            errors.append(f"'{k}' is empty or a placeholder")
    if get_ssl_enabled(lines) == "true":
        errors.append("api.ssl.enabled is true: set the node to 'Behind Proxy' in the Panel and copy the configuration again "
                      "(Wings must speak plain HTTP to the tunnel)")
    cur_remote = unquote(TOP_RE.match(lines[top["remote"]]).group(2))
    if remote and cur_remote != remote:
        warnings.append(f"remote is '{cur_remote}', expected '{remote}'")
    if port and get_api(lines, "port") != str(port):
        warnings.append(f"api.port is '{get_api(lines, 'port')}', expected '{port}'")
    host = get_api(lines, "host")
    if host not in ("127.0.0.1", "localhost"):
        warnings.append(f"api.host is '{host}': Wings would listen beyond loopback")
    sftp = find_path(lines, ["system", "sftp", "bind_address"])
    if sftp is not None and scalar_at(lines[sftp], "bind_address") not in ("127.0.0.1", "localhost"):
        warnings.append(f"system.sftp.bind_address is '{scalar_at(lines[sftp], 'bind_address')}': SFTP would listen on every interface")
    return errors, warnings


# Conservative laptop/VPS tuning (from the Phase 5 baseline of the previous stack). Applied only to keys that already exist
# in the Panel-generated file; nothing is added, nothing else is touched.
TUNING = [
    (("docker", "container_pid_limit"), "512"),          # fork-bomb containment; never 0
    # docker.tmpfs_size is deliberately NOT tuned: it caps every container's /tmp, and install containers unpack a JRE there
    (("system", "disk_check_interval"), "300"),          # lighter disk I/O than the default 150 s
    (("system", "websocket_log_count"), "100"),          # less data per console connect
    (("system", "crash_detection", "detect_clean_exit_as_crash"), "false"),   # a console `stop` is not a crash
    (("system", "backups", "write_limit"), "50"),        # MiB/s: a backup must not starve the running game
    (("system", "backups", "compression_level"), "best_speed"),
    (("api", "upload_limit"), "100"),                    # MB: equals Cloudflare's request body cap
    (("throttles", "lines"), "2000"),
    (("throttles", "line_reset_interval"), "100"),
]


def apply_tuning(lines):
    changes = []
    for path, value in TUNING:
        i = find_path(lines, list(path))
        if i is None:
            continue
        old = scalar_at(lines[i], path[-1])
        if old != value and set_scalar(lines, i, path[-1], value):
            changes.append(f"{'.'.join(path)}: {old} -> {value}")
    return changes


def network_values(game_subnet):
    import ipaddress
    net = ipaddress.ip_network(game_subnet, strict=False)
    return str(net), str(net.network_address + 1)


def patch(lines, host, port, remote, origin, trusted_proxy, sftp_host=None, tune=False, game_subnet=None):
    """Edit `lines` in place. Returns a list of human-readable changes (no secrets)."""
    changes = []
    top = top_index(lines)
    if "api" not in top or "remote" not in top:
        raise ValueError("config has no 'api' or 'remote' key")
    # remote (top-level scalar)
    old = unquote(TOP_RE.match(lines[top["remote"]]).group(2))
    if old != remote:
        lines[top["remote"]] = f'remote: "{remote}"'
        changes.append(f"remote: {old} -> {remote}")
    # api.host / api.port
    s = top["api"]
    for key, val in (("host", f'"{host}"'), ("port", str(port))):
        hit = find_in_block(lines, s, block_end(lines, s), key)
        if not hit:
            lines.insert(s + 1, f"  {key}: {val}")
            changes.append(f"api.{key}: (absent) -> {unquote(val)}")
            continue
        old = scalar_at(lines[hit[0]], key)
        if set_scalar(lines, hit[0], key, val):
            changes.append(f"api.{key}: {old} -> {unquote(val)}")
    # system.sftp.bind_address: Wings binds SFTP to every interface when this key is absent. SFTP is not proxied by Cloudflare.
    if sftp_host:
        before = find_path(lines, ["system", "sftp", "bind_address"])
        old = scalar_at(lines[before], "bind_address") if before is not None else None
        if set_path(lines, ["system", "sftp", "bind_address"], f'"{sftp_host}"') != "same":
            changes.append(f"system.sftp.bind_address: {old or '(absent)'} -> {sftp_host}")
    # docker network: the game subnet must equal GAME_NET_SUBNET (the egress guard uses it); interface must be loopback
    # (Docker Desktop refuses a bridge-gateway bind); inter-container communication off (game servers cannot reach each other)
    if game_subnet:
        subnet, gateway = network_values(game_subnet)
        for path, value in ((["docker", "network", "interface"], '"127.0.0.1"'),
                            (["docker", "network", "enable_icc"], "false"),
                            (["docker", "network", "interfaces", "v4", "subnet"], f'"{subnet}"'),
                            (["docker", "network", "interfaces", "v4", "gateway"], f'"{gateway}"')):
            before = find_path(lines, path)
            old = scalar_at(lines[before], path[-1]) if before is not None else None
            if set_path(lines, path, value) != "same":
                changes.append(f"{'.'.join(path)}: {old or '(absent)'} -> {value.strip(chr(34))}")
    # api.trusted_proxies
    if trusted_proxy:
        s = top_index(lines)["api"]
        e = block_end(lines, s)
        hit = find_in_block(lines, s, e, "trusted_proxies")
        if hit:
            if ensure_list_item(lines, hit[0], hit[1], trusted_proxy):
                changes.append(f"api.trusted_proxies += {trusted_proxy}")
        else:
            lines[e:e] = ["  trusted_proxies:", f"    - {trusted_proxy}"]
            changes.append(f"api.trusted_proxies = [{trusted_proxy}]")
    # allowed_origins (top-level list)
    top = top_index(lines)
    if "allowed_origins" in top:
        if ensure_list_item(lines, top["allowed_origins"], 0, origin):
            changes.append(f"allowed_origins += {origin}")
    else:
        while lines and lines[-1] == "":
            lines.pop()
        lines += ["allowed_origins:", f"- {origin}", ""]
        changes.append(f"allowed_origins = [{origin}]")
    if tune:
        changes += apply_tuning(lines)
    return changes


def write_atomic(path, lines):
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)) or ".", prefix=".wings-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("file")
    c.add_argument("--remote")
    c.add_argument("--port", type=int)
    g = sub.add_parser("get", help="print the scalar at a nested key path, e.g. docker network interfaces v4 subnet")
    g.add_argument("file")
    g.add_argument("path", nargs="+")
    p = sub.add_parser("patch")
    p.add_argument("file")
    p.add_argument("--out", required=True)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--remote", required=True)
    p.add_argument("--origin", required=True)
    p.add_argument("--trusted-proxy", default="127.0.0.1")
    p.add_argument("--sftp-host", default="127.0.0.1")
    p.add_argument("--tune", action="store_true", help="also apply the conservative resource/IO tuning to existing keys")
    p.add_argument("--game-subnet", help="docker.network.interfaces.v4.subnet for game containers (= GAME_NET_SUBNET)")
    a = ap.parse_args(argv)
    try:
        lines = read_lines(a.file)
    except OSError as e:
        print(f"cannot read {a.file}: {e}", file=sys.stderr)
        return 2
    if a.cmd == "get":
        i = find_path(lines, a.path)
        if i is None:
            return 1
        v = scalar_at(lines[i], a.path[-1])
        if a.path[-1] in ("token", "token_id"):      # never print credentials
            return 1
        print(v)
        return 0
    if a.cmd == "check":
        errors, warnings = check(lines, a.remote, a.port)
        for w in warnings:
            print(f"WARN {w}")
        for e in errors:
            print(f"ERROR {e}")
        return 2 if errors else 0
    errors, _ = check(lines)
    if errors:
        for e in errors:
            print(f"ERROR {e}")
        return 2
    try:
        changes = patch(lines, a.host, a.port, a.remote, a.origin, a.trusted_proxy, a.sftp_host, a.tune, a.game_subnet)
    except ValueError as e:
        print(f"ERROR {e}")
        return 2
    write_atomic(a.out, lines)
    for c in changes:
        print(f"patched {c}")
    if not changes:
        print("no changes needed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

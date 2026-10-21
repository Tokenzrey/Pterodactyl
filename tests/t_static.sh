#!/usr/bin/env bash
# Static and security checks: compose file (rendered by the real docker compose when available), secret scan,
# syntax, shellcheck (when docker can run the image), redaction, diagnose output, help/usage.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1

echo "syntax"
for f in ptero lib/*.sh tests/*.sh tests/fakebin/*; do
    bash -n "$f" 2>/dev/null && pass "bash -n $f" || fail "bash -n $f"
done
python3 -m py_compile lib/wings_config.py lib/redact.py && pass "python files compile" || fail "python files compile"
rm -rf lib/__pycache__

echo "compose.yml rendered by the real docker compose"
REALDOCKER=$(command -v docker || true)
if [[ -z $REALDOCKER ]] || ! env -u DOCKER_HOST "$REALDOCKER" compose version >/dev/null 2>&1; then
    echo "  skip docker compose not available (not verified here)"
else
    ENVF=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$ENVF'" EXIT
    grep -E '^(MARIADB|REDIS|CLOUDFLARED|PANEL|UTILITY|MCROUTER|INSTALLER|WINGS)_IMAGE=' config/versions.env >"$ENVF"
    printf '%s\n' DB_PASSWORD=dummydummydummydummydummy REDIS_PASSWORD=dummydummydummydummydummy PANEL_FQDN=panel.mytest.dev \
        ADMIN_EMAIL=ops@mytest.dev PANEL_EDGE_SUBNET=10.77.250.0/24 PANEL_BIND_PORT=18081 TUNNEL_METRICS_PORT=12041 TUNNEL_TOKEN=dummy \
        WINGS_API_PORT=18443 WINGS_SFTP_BIND=127.0.0.1 GAME_NET_SUBNET=10.201.0.0/16 >>"$ENVF"
    if env -u DOCKER_HOST "$REALDOCKER" compose --env-file "$ENVF" -f compose.yml --profile '*' config --format json >"$ENVF.json" 2>"$ENVF.err"; then
        pass "docker compose config accepts compose.yml"
        out=$(python3 - "$ENVF.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
svc = c["services"]; bad = []
for name, s in svc.items():
    for p in s.get("ports", []):
        if p.get("host_ip") != "127.0.0.1":
            bad.append(f"{name}: published port not bound to 127.0.0.1: {p}")
    if ":latest" in s["image"] or "@sha256:" not in s["image"]:
        bad.append(f"{name}: image not pinned by digest: {s['image']}")
    if "no-new-privileges:true" not in s.get("security_opt", []):
        bad.append(f"{name}: no-new-privileges missing")
    if s.get("privileged"):
        bad.append(f"{name}: privileged")
    for v in s.get("volumes", []):
        if v.get("type") == "bind":
            ok = name == "mc-router" and v.get("target") == "/routes" and v.get("read_only") and v.get("source", "").endswith("/runtime/mc-router")
            if not ok:
                bad.append(f"{name}: bind mount {v.get('source')} (only mc-router's read-only routes table may be a bind mount)")
        if "docker.sock" in str(v):
            bad.append(f"{name}: mounts the Docker socket")
    if name in ("database", "cache") and s.get("ports"):
        bad.append(f"{name}: must not publish ports")
hosts = [n for n, s in svc.items() if s.get("network_mode") == "host"]
if sorted(hosts) != ["cloudflared", "mc-router"]:
    bad.append(f"only cloudflared and mc-router may use host networking, got {hosts}")
for n in ("cloudflared", "mc-router"):
    if svc[n].get("cap_drop") != ["ALL"] or not svc[n].get("read_only"):
        bad.append(f"{n}: must run read-only with cap_drop ALL")
    if svc[n].get("ports"):
        bad.append(f"{n}: host networking has no published ports")
if svc["mc-router"].get("environment", {}).get("ROUTES_CONFIG_WATCH") != "true":
    bad.append("mc-router must watch its routes file")
if not c["networks"]["backend"].get("internal"):
    bad.append("backend network must be internal")
for n in ("database", "cache"):
    if "backend" not in svc[n]["networks"] or "edge" in svc[n]["networks"]:
        bad.append(f"{n} must be on the backend network only")
if svc["cache"].get("user") != "999:1000" or svc["cache"].get("cap_drop") != ["ALL"]:
    bad.append("cache must run as 999:1000 with cap_drop ALL")
if "requirepass" in " ".join(svc["cache"]["command"]) and "$" not in " ".join(svc["cache"]["command"]):
    bad.append("redis password must come from the environment, not be inlined")
if "dummydummy" in " ".join(svc["cache"]["command"]):
    bad.append("redis password leaked into the command line")
print("\n".join(bad) if bad else "OK")
PY
        )
        assert_eq OK "$out" "rendered compose: loopback-only ports, digest pins, no sockets/bind mounts, isolated backend"
    else
        fail "docker compose config accepts compose.yml" "$(cat "$ENVF.err")"
    fi
    rm -f "$ENVF.json" "$ENVF.err"

    echo "compose.wings.yml (Wings as a container): the exceptions are explicit and nothing else is allowed"
    if env -u DOCKER_HOST "$REALDOCKER" compose --env-file "$ENVF" -f compose.yml -f compose.wings.yml --profile '*' config --format json >"$ENVF.json" 2>"$ENVF.err"; then
        pass "docker compose config accepts compose.yml + compose.wings.yml"
        out=$(python3 - "$ENVF.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
svc = c["services"]; bad = []
BINDS = {"/var/run/docker.sock", "/var/lib/docker/containers", "/var/lib/pterodactyl", "/tmp/pterodactyl", "/var/log/pterodactyl", "/run/wings", "/etc/ssl/certs"}
for name in ("wings", "egress-guard"):
    s = svc[name]
    if "@sha256:" not in s["image"] or ":latest" in s["image"]:
        bad.append(f"{name}: image not pinned by digest: {s['image']}")
    if "no-new-privileges:true" not in s.get("security_opt", []):
        bad.append(f"{name}: no-new-privileges missing")
    if s.get("privileged"):
        bad.append(f"{name}: privileged")
    if "wings" not in s.get("profiles", []):
        bad.append(f"{name}: must sit behind the wings profile, so that a plain `up` never starts it")
for name, s in svc.items():
    if name != "egress-guard" and s.get("cap_add"):
        bad.append(f"{name}: only egress-guard may add capabilities")
    for v in s.get("volumes", []):
        if "docker.sock" in str(v) and name != "wings":
            bad.append(f"{name}: only wings may mount the Docker socket")
        if v.get("type") == "bind" and name == "wings":
            src, dst = v["source"].rstrip("/"), v["target"].rstrip("/")
            if src not in BINDS:
                bad.append(f"wings: bind mount {src} is not on the documented list")
            if src != dst:
                bad.append(f"wings: bind {src} -> {dst} breaks path identity (host path must equal container path)")
    if name == "wings":
        for p in s.get("ports", []):
            if p.get("host_ip") != "127.0.0.1":
                bad.append(f"wings: published port not on 127.0.0.1 by default: {p}")
        api = [p for p in s.get("ports", []) if p.get("target") != 2022]
        if len(api) != 1 or api[0].get("published") != str(api[0].get("target")):
            bad.append("wings: the API port must be published on the same number it listens on (api.port = Daemon Port)")
w = svc["wings"]
if {"/run/wings", "/var/lib/pterodactyl", "/tmp/pterodactyl", "/var/log/pterodactyl"} - {v.get("source", "").rstrip("/") for v in w.get("volumes", [])}:
    bad.append("wings: the four path-identity mounts must all be present")
if [v for v in w["volumes"] if v["target"] == "/etc/ssl/certs" and not v.get("read_only")]:
    bad.append("wings: /etc/ssl/certs must be read-only")
if not any(v["target"] == "/etc/pterodactyl" and v["type"] == "volume" for v in w["volumes"]):
    bad.append("wings: config must live in a named volume, not a bind mount of the repo tree")
g = svc["egress-guard"]
if g.get("network_mode") != "host" or g.get("cap_add") != ["NET_ADMIN"] or not g.get("healthcheck"):
    bad.append("egress-guard: host network, exactly NET_ADMIN, and a healthcheck that proves the rules exist")
hosts = sorted(n for n, s in svc.items() if s.get("network_mode") == "host")
if hosts != ["cloudflared", "egress-guard", "mc-router"]:
    bad.append(f"only cloudflared, mc-router and egress-guard may use host networking, got {hosts}")
print("\n".join(bad) if bad else "OK")
PY
        )
        assert_eq OK "$out" "rendered with Wings: socket and host binds only on wings, identity mounts, pinned, loopback ports, one added capability"
    else
        fail "docker compose config accepts compose.yml + compose.wings.yml" "$(cat "$ENVF.err")"
    fi
    out=$(env -u DOCKER_HOST "$REALDOCKER" compose --env-file "$ENVF" -f compose.yml -f compose.wings.yml config --services 2>&1 | sort | tr '\n' ' ')
    assert_eq "cache database panel " "$out" "without the wings profile the Wings services are not part of the stack"
    rm -f "$ENVF.json" "$ENVF.err"
fi

echo "secret scan of everything that would be committed"
hits=$(grep -rEn --exclude-dir=.git --exclude-dir=tools --exclude='*.md' --exclude=wings-config.yml \
    -e 'eyJ[A-Za-z0-9_-]{30,}' -e 'ptl[ac]_[A-Za-z0-9]{16,}' -e 'BEGIN [A-Z ]*PRIVATE KEY' -e 'AGE-SECRET-KEY-1[A-Z0-9]{20,}' \
    -e '^(DB|REDIS)_PASSWORD=[A-Za-z0-9]{16,}' -e '^(CF_API_TOKEN|TUNNEL_TOKEN)=[A-Za-z0-9._-]{12,}' . 2>/dev/null | grep -v 'dummy' || true)
assert_eq "" "$hits" "no tokens, keys or passwords in tracked files"
assert_eq "" "$(grep -E '^(PANEL_FQDN|WINGS_FQDN|ADMIN_EMAIL)=.+' config/deploy.env.example)" "deploy.env.example ships no real identity"
for pat in '/secrets/' '/backups/' '/config/deploy.env'; do
    grep -qxF "$pat" .gitignore && pass ".gitignore covers $pat" || fail ".gitignore covers $pat"
done
[[ -e config/deploy.env || -e secrets ]] && fail "no config/deploy.env or secrets/ in the repo checkout" || pass "no config/deploy.env or secrets/ in the repo checkout"

echo "scripts do not pipe the network into a shell, and do not delete user data"
assert_eq "" "$(grep -nE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh' ptero lib/*.sh || true)" "no curl|sh"
assert_eq "" "$(grep -nE 'docker (compose )?[a-z-]* ?(volume (rm|prune)|system prune)|down[^|]* -v|--volumes' ptero lib/*.sh | grep -v '^\s*#' || true)" "no volume removal / prune anywhere"
assert_eq "" "$(grep -nE 'rm -rf? [^|]*(backups|secrets|/var/lib/pterodactyl)' ptero lib/*.sh || true)" "no rm of backups, secrets or Wings data"

echo "help and usage"
OUT=$("$REPO/ptero" help 2>&1); RC=$?
assert_eq 0 "$RC" "help exits 0"
for w in init setup status backup restore update diagnose "wings install" "tunnel set-token"; do
    assert_contains "$OUT" "$w" "help mentions: $w"
done
OUT=$("$REPO/ptero" bogus 2>&1); RC=$?
assert_eq 2 "$RC" "unknown command exits 2"

echo "redaction"
sandbox; trap sandbox_cleanup EXIT
valid_config
sec=$(cat "$R/secrets/db_password")
tok=$(cat "$R/secrets/tunnel_token")
apikey=$(printf 'ptl%s_ABCDEFGHIJKLMNOPQRST' a)   # built at runtime so the secret scan above stays meaningful
text=$(printf 'conn: %s\nT: %s\ntoken: AAAABBBBCCCCDDDD\nAuthorization: Bearer abc123def456\nkey %s\nplain line\n' "$sec" "$tok" "$apikey")
red=$(cd "$R" && PTERO_ROOT="$R" bash -c 'source lib/common.sh; redact' <<<"$text")
assert_not_contains "$red" "$sec" "exact secret values are masked"
assert_not_contains "$red" "$tok" "the tunnel token is masked"
assert_not_contains "$red" "AAAABBBBCCCCDDDD" "token: lines are masked"
assert_not_contains "$red" "abc123def456" "bearer tokens are masked"
assert_not_contains "$red" "ptla_ABCDEFGH" "Panel API keys are masked"
assert_contains "$red" "plain line" "ordinary text is kept"

echo "diagnose never contains a secret"
seed_installed
p setup
p diagnose
assert_eq 0 "$RC" "diagnose exits 0"
assert_not_contains "$OUT" "$sec" "no DB password"
assert_not_contains "$OUT" "$(cat "$R/secrets/redis_password")" "no Redis password"
assert_not_contains "$OUT" "$tok" "no tunnel token"
assert_contains "$OUT" "===== preflight =====" "has a preflight section"
assert_contains "$OUT" "panel.mytest.dev" "shows the (non-secret) hostnames"
assert_contains "$OUT" "secrets/db_password: present, mode 600" "reports secret files without their content"
p diagnose --output "$SB/report.txt"
assert_mode "$SB/report.txt" 600 "report file is 600"
p diagnose --output "$SB/report.txt"
assert_eq 4 "$RC" "refuses to overwrite an existing report"

echo "the suite cannot act on this machine (an unprotected run once stopped and removed a live stack)"
gt=$(mktemp -d "${TMPDIR:-/tmp}/ptero-guard.XXXXXX")
mkdir -p "$gt/tests/fakebin" "$gt/lib" "$gt/systemd" "$gt/eggs" "$gt/extensions" "$gt/config"
cp tests/lib.sh "$gt/tests/"
cp tests/fakebin/* "$gt/tests/fakebin/" && rm -f "$gt/tests/fakebin/docker"
touch "$gt/ptero" "$gt/compose.yml" "$gt/config/versions.env" "$gt/config/deploy.env.example"
out=$(PTERO_TEST_BASE_TMP="$gt" bash -c 'source "$1/tests/lib.sh"; sandbox; echo SURVIVED' _ "$gt" 2>&1); rc=$?
assert_eq 99 "$rc" "lib.sh stops (exit 99) when a faked tool would resolve to something else than the sandbox copy"
assert_contains "$out" "FATAL: docker resolves to" "and names the tool"
assert_not_contains "$out" "SURVIVED" "and nothing after it runs"
assert_eq 0 "$(find "$gt" -maxdepth 1 -name 'ptero-test.*' | wc -l | tr -d ' ')" "and it leaves no sandbox directory behind"
out=$(PTERO_TEST_BASE_TMP="$gt/does-not-exist" bash -c 'source "$1/tests/lib.sh"; sandbox; echo SURVIVED' _ "$gt" 2>&1); rc=$?
assert_eq 99 "$rc" "sandbox() stops when it cannot create its directory (an empty one would turn the repo copy into /root)"
assert_not_contains "$out" "SURVIVED" "and nothing after it runs"
cp tests/fakebin/docker "$gt/tests/fakebin/docker"
chmod -x "$gt"/tests/fakebin/*
out=$(PTERO_TEST_BASE_TMP="$gt" bash -c 'source "$1/tests/lib.sh"; sandbox; command -v docker; [[ -x $(command -v docker) ]] && echo EXECUTABLE' _ "$gt" 2>&1); rc=$?
assert_eq 0 "$rc" "fakes that are NOT executable in the checkout (git stores them as 100644 on Windows) still work"
assert_contains "$out" "EXECUTABLE" "because the sandbox copy is made executable"
assert_contains "$out" "/fakebin/docker" "and is what docker resolves to"
mkdir -p "$gt/realbin"; printf '#!/bin/sh\nexit 0\n' >"$gt/realbin/docker"; chmod +x "$gt/realbin/docker"
out=$(cd "$R" && PATH="$gt/realbin:$PATH" ./ptero version 2>&1); rc=$?
assert_eq 4 "$rc" "ptero itself refuses PTERO_TEST_MODE=1 when docker is not the test fake"
assert_contains "$out" "not the test fake" "and says why"
assert_eq "unix:///nonexistent/ptero-tests-never-reach-a-real-daemon.sock" "$DOCKER_HOST" "DOCKER_HOST points at a socket that does not exist, for any real client that slips through"
rm -rf -- "$gt"

echo "shellcheck"
# The only deliberate use of the real docker in the suite: a throw-away shellcheck container with the repo mounted read-only.
# lib.sh points DOCKER_HOST at a socket that does not exist, so these two calls clear it for themselves.
if [[ -n $REALDOCKER && ${SKIP_SHELLCHECK:-0} != 1 ]] && env -u DOCKER_HOST "$REALDOCKER" image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
    out=$(env -u DOCKER_HOST "$REALDOCKER" run --rm -v "$REPO":/mnt:ro koalaman/shellcheck:stable -x -S warning -e SC1091 ptero lib/*.sh 2>&1); rc=$?
    assert_eq 0 "$rc" "shellcheck (warnings and above) is clean"
    [[ $rc -ne 0 ]] && printf '%s\n' "$out" | head -n 40
elif command -v shellcheck >/dev/null; then
    shellcheck -x -S warning -e SC1091 ptero lib/*.sh && pass "shellcheck is clean" || fail "shellcheck is clean"
else
    echo "  skip shellcheck not available (docker pull koalaman/shellcheck:stable, or install shellcheck)"
fi

finish

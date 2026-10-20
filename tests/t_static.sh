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
if [[ -z $REALDOCKER ]] || ! "$REALDOCKER" compose version >/dev/null 2>&1; then
    echo "  skip docker compose not available (not verified here)"
else
    ENVF=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$ENVF'" EXIT
    grep -E '^(MARIADB|REDIS|CLOUDFLARED|PANEL|UTILITY|MCROUTER|INSTALLER)_IMAGE=' config/versions.env >"$ENVF"
    printf '%s\n' DB_PASSWORD=dummydummydummydummydummy REDIS_PASSWORD=dummydummydummydummydummy PANEL_FQDN=panel.mytest.dev \
        ADMIN_EMAIL=ops@mytest.dev PANEL_EDGE_SUBNET=10.77.250.0/24 PANEL_BIND_PORT=18081 TUNNEL_METRICS_PORT=12041 TUNNEL_TOKEN=dummy >>"$ENVF"
    if "$REALDOCKER" compose --env-file "$ENVF" -f compose.yml --profile '*' config --format json >"$ENVF.json" 2>"$ENVF.err"; then
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

echo "shellcheck"
if [[ -n $REALDOCKER && ${SKIP_SHELLCHECK:-0} != 1 ]] && "$REALDOCKER" image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
    out=$("$REALDOCKER" run --rm -v "$REPO":/mnt:ro koalaman/shellcheck:stable -x -S warning -e SC1091 ptero lib/*.sh 2>&1); rc=$?
    assert_eq 0 "$rc" "shellcheck (warnings and above) is clean"
    [[ $rc -ne 0 ]] && printf '%s\n' "$out" | head -n 40
elif command -v shellcheck >/dev/null; then
    shellcheck -x -S warning -e SC1091 ptero lib/*.sh && pass "shellcheck is clean" || fail "shellcheck is clean"
else
    echo "  skip shellcheck not available (docker pull koalaman/shellcheck:stable, or install shellcheck)"
fi

finish

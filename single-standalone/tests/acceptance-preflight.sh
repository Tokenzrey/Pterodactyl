#!/usr/bin/env bash
# Read-only preflight for the Task 23 acceptance run. Run it on each host before step 1, from the code root:
#   bash single-standalone/tests/acceptance-preflight.sh
# It calls no docker, ufw, iptables, ssh, curl or network tool and writes nothing: it reads files and asks `command -v`.
# One line per check (PASS, FAIL or NOTE); it never prints a secret. Exit 0 when every check passes, 3 when one fails.
# MCCTL_ROOT (default: the code folder, which holds ./mcctl) locates config/ and secrets/. PREFLIGHT_SYS (default /) is the
# root that /proc, /lib, /etc, /run and /var are read under; the tests point it at a fake tree.
set -u
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 3
HOME_DIR=$(cd -- "$here/.." && pwd -P) || exit 3
ROOT=${MCCTL_ROOT:-$HOME_DIR}
SYS=${PREFLIGHT_SYS:-}
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
note() { printf 'NOTE  %s\n' "$1"; }

# cfg KEY: the value from the environment, else from config/mcctl.env (read as text, never sourced)
cfg() {
    local v=${!1:-}
    [[ -n $v ]] || v=$(sed -n "s/^$1=//p" "$ROOT/config/mcctl.env" 2>/dev/null | tail -n 1)
    printf '%s' "$v"
}

# mod_present NAME: the module is loaded, built into this kernel, or a loadable file for it exists
krel=$(cat "$SYS/proc/sys/kernel/osrelease" 2>/dev/null)
mod_present() {
    [[ -n $krel ]] || return 1
    grep -q "^$1 " "$SYS/proc/modules" 2>/dev/null && return 0
    grep -q "/$1\.ko" "$SYS/lib/modules/$krel/modules.builtin" 2>/dev/null && return 0
    [[ -n $(find "$SYS/lib/modules/$krel" -name "$1.ko*" -print -quit 2>/dev/null) ]]
}

# host facts (record them in acceptance.md)
note "kernel ${krel:-unknown} (uname -r)"
note "OS $(sed -n 's/^PRETTY_NAME=//p' "$SYS/etc/os-release" 2>/dev/null | tr -d '"')"
if grep -qi microsoft "$SYS/proc/version" 2>/dev/null; then note "WSL kernel detected (host B)"; else note "no WSL kernel (host A)"; fi
[[ -n ${DOCKER_HOST:-} ]] && note "DOCKER_HOST is ${DOCKER_HOST}: the run uses that daemon; unset it for the host daemon"
note "step 1 changes the firewall: keep a second SSH session open, or use the provider console, before firewall apply"

# bash and tools
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    pass "bash ${BASH_VERSION%%[( ]*} (4.4 or later)"
else
    fail "bash" "${BASH_VERSION}: mcctl needs bash 4.4 or later"
fi
for c in docker jq curl tar ss sort iptables ufw systemd-run; do
    if command -v "$c" >/dev/null 2>&1; then pass "command $c"; else fail "command $c" "not on PATH; install it"; fi
done
if [[ $(printf '1.10\n1.9\n' | sort -V | head -n 1) == 1.9 ]]; then pass "sort -V (GNU sort)"; else fail "sort -V" "GNU sort is required"; fi
[[ -e $SYS/run/systemd/system ]] || note "systemd is not running here: systemd-run cannot arm the dead-man timer, so firewall apply refuses (exit 3)"

# mcctl, configuration, secrets
if [[ -x $HOME_DIR/mcctl ]]; then pass "mcctl is executable"; else fail "mcctl is executable" "run: chmod +x $HOME_DIR/mcctl"; fi
for k in MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID; do
    if [[ -n $(cfg "$k") ]]; then pass "$k is set"
    elif [[ $k != MCCTL_DOMAIN ]] && grep -qi microsoft "$SYS/proc/version" 2>/dev/null; then note "$k not checked on WSL: DNS records need the public host (host A)"
    else fail "$k is set" "set it in $ROOT/config/mcctl.env (see config/mcctl.env.example)"; fi
done
for f in cloudflare_token curseforge_api_key; do
    p=$ROOT/secrets/$f
    if [[ ! -f $p ]]; then fail "secrets/$f" "missing; create it, mode 600"; continue; fi
    m=$(stat -c %a -- "$p" 2>/dev/null)
    if [[ $m == 600 || $m == 400 ]]; then pass "secrets/$f exists, mode $m"; else fail "secrets/$f mode" "is ${m:-unknown}; run: chmod 600 $p"; fi
done

# kernel and Docker
for m in xt_connlimit xt_hashlimit xt_conntrack; do
    if mod_present "$m"; then pass "kernel module $m (loaded, built in, or loadable)"
    else fail "kernel module $m" "not loaded, not built in, no file for kernel ${krel:-unknown}"; fi
done
if [[ -e $SYS/var/run/docker.sock ]]; then pass "docker socket /var/run/docker.sock exists"
else fail "docker socket" "/var/run/docker.sock missing: start Docker Engine, or Docker Desktop with WSL integration"; fi

if ((fails == 0)); then
    echo "preflight: all checks passed"
    exit 0
fi
echo "preflight: $fails check(s) failed; fix them before step 1"
exit 3

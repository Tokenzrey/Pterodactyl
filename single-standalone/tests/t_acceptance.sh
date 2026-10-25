#!/usr/bin/env bash
# The acceptance pack's preflight (tests/acceptance-preflight.sh) on a fake host: it passes on a complete host, names each gap it
# checks, calls no command (the fakes and logging stand-ins see nothing), writes nothing, and prints no secret. Fakes only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
unset MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID
# the preflight runs from a copy inside the sandbox, so its ./mcctl (the code folder) is the sandbox's, not the tree's
mkdir -p "$SB/tests" && cp "$REPO/tests/acceptance-preflight.sh" "$SB/tests/" || exit 99
PRE=$SB/tests/acceptance-preflight.sh

# stand-ins that log any call: the preflight may test that these exist (command -v), never run them
for t in ssh wget nc ping sudo; do
    printf '#!/bin/sh\necho "UNKNOWN %s $*" >>"$FAKE_STATE/calls.log"; exit 97\n' "$t" >"$SB/fakebin/$t"
    chmod +x "$SB/fakebin/$t"
done

# a complete fake host: kernel modules (two loaded, one built in), systemd, the Docker socket, a config and two secrets
SYS=$SB/sys
mkdir -p "$SYS/proc/sys/kernel" "$SYS/lib/modules/6.6.87-test" "$SYS/run/systemd/system" "$SYS/var/run" "$SYS/etc"
printf '6.6.87-test\n' >"$SYS/proc/sys/kernel/osrelease"
printf 'PRETTY_NAME="Ubuntu 24.04 LTS"\n' >"$SYS/etc/os-release"
modules() { printf 'xt_connlimit 16384 0 - Live 0x0\nxt_hashlimit 1 0 - Live 0x0\n' >"$SYS/proc/modules"; }
modules
printf 'kernel/net/netfilter/xt_conntrack.ko\n' >"$SYS/lib/modules/6.6.87-test/modules.builtin"
touch "$SYS/var/run/docker.sock"
mkdir -p "$SB/secrets" "$SB/config"
plant_canary "$SB/secrets/cloudflare_token"; CF_TOKEN=$CANARY
plant_canary "$SB/secrets/curseforge_api_key"; CF_KEY=$CANARY
printf '%s\n' MCCTL_DOMAIN=mc-test.example.com MCCTL_PUBLIC_IPV4=203.0.113.7 MCCTL_CF_ZONE_ID=0123456789abcdef0123456789abcdef \
    >"$SB/config/mcctl.env"

snap()    { find "$SB" -type f -printf '%p %s %T@\n' | sort; }
run_pre() { OUT=$(cd "$SB" && PREFLIGHT_SYS=$SYS bash "$PRE" 2>&1); RC=$?; }

echo "a complete host"
before=$(snap)
run_pre
assert_eq 0 "$RC" "every check passes: exit 0"
assert_contains "$OUT" "PASS  command docker" "docker is found with command -v"
assert_contains "$OUT" "PASS  kernel module xt_conntrack" "a module built into the kernel counts"
assert_not_contains "$OUT" "FAIL" "no FAIL line"
assert_eq "" "$(calls)" "no command ran: the fakes and the stand-ins saw no call"
assert_eq "$before" "$(snap)" "the preflight wrote nothing (every file keeps its size and mtime)"
assert_not_contains "$OUT" "$CF_TOKEN" "the Cloudflare token is not printed"
assert_not_contains "$OUT" "$CF_KEY" "the CurseForge key is not printed"

echo "gaps are named"
mv "$SB/secrets/curseforge_api_key" "$SB/secrets/k.bak"
run_pre; assert_eq 3 "$RC" "a missing CurseForge key: exit 3"
assert_contains "$OUT" "FAIL  secrets/curseforge_api_key: missing" "and the key is named"
mv "$SB/secrets/k.bak" "$SB/secrets/curseforge_api_key"
chmod 644 "$SB/secrets/cloudflare_token"
run_pre; assert_contains "$OUT" "FAIL  secrets/cloudflare_token mode" "a token readable by others is named"
chmod 600 "$SB/secrets/cloudflare_token"
sed -i '/^MCCTL_CF_ZONE_ID=/d' "$SB/config/mcctl.env"
run_pre; assert_contains "$OUT" "FAIL  MCCTL_CF_ZONE_ID is set" "a config key left empty is named"
printf '%s\n' MCCTL_CF_ZONE_ID=0123456789abcdef0123456789abcdef >>"$SB/config/mcctl.env"
printf 'xt_connlimit 16384 0 - Live 0x0\n' >"$SYS/proc/modules"
run_pre; assert_contains "$OUT" "FAIL  kernel module xt_hashlimit" "a module neither loaded nor built in is named"
modules
rm -f "$SYS/var/run/docker.sock"
run_pre; assert_contains "$OUT" "FAIL  docker socket" "no Docker socket is named"
touch "$SYS/var/run/docker.sock"
chmod -x "$SB/mcctl"
run_pre; assert_contains "$OUT" "FAIL  mcctl is executable" "a mcctl without the executable bit is named"
chmod +x "$SB/mcctl"
run_pre; assert_eq 0 "$RC" "the complete host passes again"

finish

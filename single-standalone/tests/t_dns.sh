#!/usr/bin/env bash
# MCCTL_DNS=off (local play): the setting itself, create and delete without Cloudflare (E1: the call log has no curl), the Cloudflare
# functions doing nothing, and the router published on 127.0.0.1 only. MCCTL_DNS=on is what t_servers.sh and t_cloudflare.sh cover.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
sandbox
unset MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID MCCTL_DNS
reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }

echo "the setting: on by default, on or off only, off names the servers mc.local"
m doctor; assert_contains "$OUT" "DNS on" "the default is on"
MCCTL_DNS=off m doctor; assert_contains "$OUT" "DNS off: local play" "off is shown by doctor"
assert_contains "$OUT" "mc.local" "and the names are under mc.local when no domain is set"
MCCTL_DNS=maybe m doctor; assert_eq 3 "$RC" "MCCTL_DNS=maybe: EX_PREFLIGHT"
assert_contains "$OUT" "MCCTL_DNS='maybe' must be on" "and the message says what it accepts"

echo "create with MCCTL_DNS=off: no zone, no public address, no token, no Cloudflare call"
reset
MCCTL_DNS=off m create s1 --type PAPER --accept-eula
assert_eq 0 "$RC" "create s1 with local play: exit 0"
assert_eq 0 "$(count_calls curl)" "no curl call (no Cloudflare)"
assert_eq 0 "$(count_calls dns_records)" "no DNS record was asked for or made"
assert_contains "$OUT" "127.0.0.1 s1.mc.local" "create prints the hosts-file line for this machine"
assert_contains "$(<"$SB/servers/s1/compose.yaml")" "s1.mc.local" "the router label is the local name"

echo "delete with MCCTL_DNS=off: no DNS call, and it says so"
reset
MCCTL_DNS=off MCCTL_YES=1 m delete s1
assert_eq 0 "$RC" "delete s1 with local play: exit 0"
assert_eq 0 "$(count_calls curl)" "no curl call"
assert_contains "$OUT" "DNS is off: no DNS record is touched" "delete says no DNS record is touched"
assert_no_file "$SB/servers/s1" "the server folder is gone"

echo "the Cloudflare functions do nothing with MCCTL_DNS=off (and need no token)"
reset
MCCTL_DNS=off cf_ready; assert_eq 0 "$?" "cf_ready: 0 without a zone, an address or a token"
out=$(MCCTL_DNS=off cf_create_record s1); assert_eq 0 "$?" "cf_create_record: 0"
assert_eq "" "$out" "and prints nothing"
MCCTL_DNS=off cf_delete_record s1; assert_eq 0 "$?" "cf_delete_record: 0"
MCCTL_DNS=off cf_delete_server s1; assert_eq 0 "$?" "cf_delete_server: 0"
assert_eq 0 "$CF_FOUND" "and found nothing"
MCCTL_DNS=off cf_relabel_record s1 old new; assert_eq 0 "$?" "cf_relabel_record: 0"
assert_eq "" "$(calls)" "none of them reached curl"

echo "the hosts-file hint: only with DNS off"
out=$(MCCTL_DNS=off dns_hint s2.mc.local 2>&1)
assert_contains "$out" "127.0.0.1 s2.mc.local" "off: the line is printed"
out=$(MCCTL_DNS=on dns_hint s2.mc.local 2>&1)
assert_eq "" "$out" "on: nothing is printed"

echo "the router publishes its game port on 127.0.0.1 with DNS off, on every address with DNS on"
bind_of() { ( docker() { printf '%s\n' "$MCCTL_ROUTER_BIND"; }; stack_dc up ); }
assert_eq "127.0.0.1" "$(MCCTL_DNS=off bind_of)" "off: 127.0.0.1"
assert_eq "0.0.0.0" "$(MCCTL_DNS=on bind_of)" "on: 0.0.0.0, as before"

sandbox_cleanup
finish

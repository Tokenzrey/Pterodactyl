#!/usr/bin/env bash
# init, configuration validation, secrets handling, tunnel token handling
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap sandbox_cleanup EXIT

echo "init"
p status
assert_eq 3 "$RC" "status without deploy.env exits 3"
assert_contains "$OUT" "Run ./ptero init" "tells the operator to run init"

p init
assert_eq 0 "$RC" "init succeeds"
assert_file "$R/config/deploy.env" "deploy.env created"
assert_mode "$R/secrets" 700 "secrets/ is 700"
assert_mode "$R/secrets/db_password" 600 "db_password is 600"
assert_eq 49 "$(wc -c <"$R/secrets/db_password" | tr -d ' ')" "db_password is 48 hex characters + newline"
sum1=$(sha256sum "$R"/secrets/* "$R/config/deploy.env" | sha256sum)
p init
sum2=$(sha256sum "$R"/secrets/* "$R/config/deploy.env" | sha256sum)
assert_eq "$sum1" "$sum2" "second init changes nothing (idempotent)"
assert_not_contains "$OUT" "generated" "second init generates no new secret"

echo "validation: the shipped example is rejected until edited"
p status
assert_eq 3 "$RC" "unedited deploy.env exits 3"
assert_contains "$OUT" "PANEL_FQDN" "names PANEL_FQDN"
assert_contains "$OUT" "PTERO_ACCEPT_BETA=yes" "explains the beta gate"

echo "validation: individual rules"
valid_config
p status
assert_not_contains "$OUT" "configuration is not valid" "valid config passes validation"

bad() { # bad "sed expression" "expected message" "description"
    cp "$R/config/deploy.env" "$SB/deploy.env.bak"
    sed -i "$1" "$R/config/deploy.env"
    p status
    assert_eq 3 "$RC" "$3: exit 3"
    assert_contains "$OUT" "$2" "$3: message"
    cp "$SB/deploy.env.bak" "$R/config/deploy.env"
}
bad 's/^PANEL_FQDN=.*/PANEL_FQDN=panel.example.com/' "PANEL_FQDN" "example.com placeholder rejected"
bad 's#^PANEL_FQDN=.*#PANEL_FQDN=https://panel.mytest.dev#' "PANEL_FQDN" "scheme in hostname rejected"
bad 's/^WINGS_FQDN=.*/WINGS_FQDN=panel.mytest.dev/' "must be different" "same hostname for panel and wings rejected"
bad 's/^ADMIN_EMAIL=.*/ADMIN_EMAIL=you@example.com/' "ADMIN_EMAIL" "placeholder e-mail rejected"
bad 's/^PTERO_ACCEPT_BETA=.*/PTERO_ACCEPT_BETA=no/' "pre-release" "beta not acknowledged"
bad 's/^PANEL_BIND_PORT=.*/PANEL_BIND_PORT=99999/' "PANEL_BIND_PORT" "port out of range rejected"
bad 's/^WINGS_API_PORT=.*/WINGS_API_PORT=18081/' "must all differ" "duplicate ports rejected"
bad 's#^PANEL_EDGE_SUBNET=.*#PANEL_EDGE_SUBNET=8.8.8.0/24#' "PANEL_EDGE_SUBNET" "public subnet rejected"
bad 's#^PANEL_EDGE_SUBNET=.*#PANEL_EDGE_SUBNET=10.77.250.5/24#' "PANEL_EDGE_SUBNET" "non-network address rejected"
bad 's/^APP_TIMEZONE=.*/APP_TIMEZONE=Mars\/Base/' "APP_TIMEZONE" "unknown timezone rejected"
bad 's/^WINGS_REMOTE_MODE=.*/WINGS_REMOTE_MODE=sideways/' "WINGS_REMOTE_MODE" "bad remote mode rejected"

echo "validation: no code execution from the config file"
cp "$R/config/deploy.env" "$SB/deploy.env.bak"
echo 'ADMIN_EMAIL=$(touch '"$SB"'/pwned)@mytest.dev' >>"$R/config/deploy.env"
p status
assert_no_file "$SB/pwned" "command substitution in deploy.env is never executed"
assert_eq 3 "$RC" "the unsafe line is rejected"
cp "$SB/deploy.env.bak" "$R/config/deploy.env"

echo "validation: pinned versions"
cp "$R/config/versions.env" "$SB/versions.bak"
sed -i 's#^PANEL_IMAGE=.*#PANEL_IMAGE=ghcr.io/pterodactyl/panel:latest#' "$R/config/versions.env"
p status
assert_eq 3 "$RC" "floating :latest image rejected"
assert_contains "$OUT" "pinned by digest" "says why"
cp "$SB/versions.bak" "$R/config/versions.env"

echo "secrets"
chmod 644 "$R/secrets/db_password"
p status
assert_eq 3 "$RC" "world-readable secret rejected"
assert_contains "$OUT" "chmod 600 secrets/db_password" "gives the fix"
chmod 600 "$R/secrets/db_password"
printf 'short\n' >"$R/secrets/redis_password"
p status
assert_eq 3 "$RC" "weak secret rejected"
printf '%s\n' "$(printf 'a%.0s' {1..40})" >"$R/secrets/redis_password"
p status
assert_not_contains "$OUT" "redis_password" "strong alphanumeric secret accepted"
rm "$R/secrets/tunnel_token"
: >"$FAKE_STATE/calls.log"
p setup
assert_eq 0 "$RC" "setup tolerates a missing token"
assert_contains "$OUT" "WITHOUT the tunnel" "and says it starts without the tunnel"
assert_not_contains "$(calls)" "--profile tunnel" "the tunnel profile is not enabled without a token"
valid_config

echo "tunnel token"
rm -f "$R/secrets/tunnel_token"
tok=$(printf '%s' '{"a":"acct","t":"tid","s":"c2VjcmV0"}' | base64 -w0)
OUT=$(cd "$R" && printf '%s\n' "$tok" | ./ptero tunnel set-token 2>&1); RC=$?
assert_eq 0 "$RC" "token from stdin accepted"
assert_mode "$R/secrets/tunnel_token" 600 "stored mode 600"
assert_not_contains "$OUT" "$tok" "the token is never echoed"
rm -f "$R/secrets/tunnel_token"
OUT=$(cd "$R" && printf 'docker run cloudflare/cloudflared tunnel --no-autoupdate run --token %s\n' "$tok" | ./ptero tunnel set-token 2>&1); RC=$?
assert_eq 0 "$RC" "a pasted 'cloudflared ... --token X' line is reduced to the token"
assert_eq "$tok" "$(tr -d '\n' <"$R/secrets/tunnel_token")" "and the stored value is exactly the token"
OUT=$(cd "$R" && echo "not-a-token" | ./ptero tunnel set-token 2>&1); RC=$?
assert_eq 2 "$RC" "garbage token rejected with exit 2"
assert_eq "$tok" "$(tr -d '\n' <"$R/secrets/tunnel_token")" "and the stored token is untouched"

p tunnel info
assert_contains "$OUT" "http://127.0.0.1:18081" "tunnel info prints the panel origin"
assert_contains "$OUT" "http://127.0.0.1:18443" "tunnel info prints the wings origin"
assert_contains "$OUT" "Cloudflare Access" "tunnel info warns about Access on wings"

finish

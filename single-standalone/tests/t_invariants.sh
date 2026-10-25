#!/usr/bin/env bash
# E3: static rules for the whole tree. No docker, no sandbox; reads files only.
#   - bash -n on every .sh, on mcctl and on the fakes
#   - no eval, no sudo (in mcctl, lib/, templates/ and the test infrastructure; test files may name them to assert their absence)
#   - every recursive rm in lib/ sits on a line, or directly under a line, that calls safe_path or valid_server_name, or has a
#     literal target
#   - no CR byte in mcctl, lib/, tests/, templates/
#   - every cmd_* function in lib/ is named in at least one tests/t_*.sh
#   - shellcheck, when installed
#   - no compose template publishes a port, opens the host or carries a plain credential (Task 2)
#   - the CurseForge API key is only ever named as CF_API_KEY_FILE in mcctl, lib/ and templates/ (Task 4)
#   - no line that names rcon-cli also names a password: rcon-cli finds it inside the container (Task 5)
#   - the router stack template has only its stated exceptions: host network and NET_ADMIN for the egress guard, one published
#     port (25565), the Docker socket read-only, no plain credential (Task 6)
#   - curl runs only in lib/cloudflare.sh, reads its configuration from stdin (--config -) and has no credential on its line; the
#     bearer token is only ever printed into that stdin; the token file is named only in lib/cloudflare.sh; every DNS record is
#     written proxied: false; .gitignore keeps trash/ out of git (Task 7)
#   - the compose rules run on each template file on its own: the server template (no port, no host access), the router stack
#     (exactly one published port, 25565, and no SFTP) and the SFTP template (Task 9): exactly one published port, 2222 to the
#     container's 22, bound to 127.0.0.1 (or 0.0.0.0, which mcctl writes only for MCCTL_SFTP_PUBLIC=1; tests/t_sftp.sh checks
#     that), the stated capabilities only, no Docker socket, no plain credential, and no $ anywhere. The same rule runs on the file
#     sftp_render really generates, for both values of MCCTL_SFTP_PUBLIC.
# Each rule is a function over file lists, and is run against a small fixture below so a rule that can never fire is caught.
# Every task appends its own rules here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1

# --- the rules -------------------------------------------------------------------------------------------------------------

# rm_rf_unguarded FILE...: recursive rm lines with a computed target and no safe_path / valid_server_name on the line or the
# line above it (the previous non-blank, non-comment line)
rm_rf_unguarded() {
    (($# > 0)) || return 0
    awk '
        FNR == 1 { prev = "" }
        /^[ \t]*(#|$)/ { next }
        {
            if (match($0, /(^|[^A-Za-z0-9_])rm[ \t]+(-[A-Za-z-]+[ \t]+)*-([A-Za-z]*[rR][A-Za-z]*|-recursive)([ \t]|$)/)) {
                seg = substr($0, RSTART)
                sub(/[;|&].*$/, "", seg)
                if ($0 !~ /safe_path|valid_server_name/ && prev !~ /safe_path|valid_server_name/ && (seg ~ /[$`{]/ || $0 ~ /xargs/))
                    print FILENAME ":" FNR ": " $0
            }
            prev = $0
        }' "$@"
}

# files_with_cr PATH...: text files under PATH... that contain a CR byte
files_with_cr() { grep -rlIU $'\r' -- "$@" 2>/dev/null; }   # -U: Git Bash's grep would otherwise strip the CR before matching

# untested_cmds LIBDIR TESTDIR: cmd_* functions defined under LIBDIR that no TESTDIR/t_*.sh names (this file does not count)
untested_cmds() {
    local f name tests=()
    for f in "$2"/t_*.sh; do [[ -f $f && $(basename "$f") != t_invariants.sh ]] && tests+=("$f"); done
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        ((${#tests[@]})) && grep -qw -- "$name" "${tests[@]}" && continue
        echo "$name"
    done < <(find "$1" -type f -name '*.sh' -exec grep -hoE '^[[:space:]]*(function[[:space:]]+cmd_[A-Za-z0-9_]+|cmd_[A-Za-z0-9_]+[[:space:]]*\(\))' {} + 2>/dev/null |
             sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)$//' | sort -u)
}

# sources_env FILE...: non-comment lines that `source` (or `.`) an *.env file. Configuration is parsed (lib/config.sh), never
# executed, so a typo or a pasted $(...) in config/mcctl.env or a server.env cannot run code. (A path held in a variable is not seen.)
sources_env() {
    (($# > 0)) || return 0
    grep -nHE '(^|[;&|({[:space:]])(source|\.)[[:space:]]+[^#]*\.env([^[:alnum:]_]|$)' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#'
}

# template_violations FILE...: non-comment lines of a compose template that publish a port or open the host (ports, privileged,
# pid, userns_mode, cap_add, devices, or a network_mode other than "service:mc", the backup sidecar sharing the namespace of its
# server), or that write a credential as a plain value (a key or KEY= entry named *PASSWORD, *PASSWD, *SECRET, *TOKEN or *_KEY;
# the *_FILE form is fine)
template_violations() {
    (($# > 0)) || return 0
    {
        grep -nHE '^[[:space:]]*(ports|privileged|pid|userns_mode|cap_add|devices):|^[[:space:]]*(- *)?"?[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)(:|=)' -- "$@"
        grep -nHE '^[[:space:]]*network_mode:' -- "$@" | grep -Ev 'network_mode:[[:space:]]*"service:mc"[[:space:]]*$'
    } 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' | sort -t: -k1,1 -k2,2n
}

# plain_cf_key FILE...: non-comment lines that name CF_API_KEY other than as CF_API_KEY_FILE. The key is a file under secrets/,
# passed to the container by path; a line that writes CF_API_KEY= or CF_API_KEY: would put the value in the environment.
plain_cf_key() {
    (($# > 0)) || return 0
    grep -nHE 'CF_API_KEY([^A-Za-z0-9_]|$)' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#'
}

# rcon_password_argv FILE...: non-comment lines that name rcon-cli together with a password (--password, -p, or anything
# spelled "pass..."). mcctl runs `docker exec ... rcon-cli CMD...` and rcon-cli finds the password itself, so a password is never
# an argument, an -e value or a variable on such a line.
rcon_password_argv() {
    (($# > 0)) || return 0
    grep -nHE 'rcon-cli' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' |
        grep -iE -- '--password|[[:space:]]-p([[:space:]=]|$)|pass'
}

# stack_violations FILE...: non-comment lines of the router stack template (templates/stack.compose.yml) that go beyond its stated
# exceptions. It may use network_mode: host and cap_add: [NET_ADMIN] (the egress guard), publish "25565:25565" once, and mount
# docker.sock read-only. Flagged: privileged, pid, userns_mode or devices; any other network_mode, cap_add or published port (or
# the same port twice); a docker.sock mount without :ro; a credential written as a plain value (a key or KEY= entry named
# *PASSWORD, *PASSWD, *SECRET, *TOKEN or *_KEY; the *_FILE form is fine)
stack_violations() {
    (($# > 0)) || return 0
    awk '
        function bad() { print FILENAME ":" FNR ": " $0 }
        /^[ \t]*#/ { next }
        inports && /^[ \t]*-/ { if ($0 !~ /^[ \t]*-[ \t]*"25565:25565"[ \t]*(#.*)?$/ || ++n > 1) bad(); next }
        { inports = 0 }
        /^[ \t]*ports:/ { inports = 1; if ($0 !~ /^[ \t]*ports:[ \t]*(#.*)?$/) bad() }
        /^[ \t]*(privileged|pid|userns_mode|devices):/ { bad() }
        /^[ \t]*network_mode:/ && $0 !~ /^[ \t]*network_mode:[ \t]*host[ \t]*(#.*)?$/ { bad() }
        /^[ \t]*cap_add:/ && $0 !~ /^[ \t]*cap_add:[ \t]*\[[ \t]*NET_ADMIN[ \t]*\][ \t]*(#.*)?$/ { bad() }
        /docker\.sock/ && $0 !~ /docker\.sock:ro"?[ \t]*(#.*)?$/ { bad() }
        /^[ \t]*(- *)?"?[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)(:|=)/ { bad() }' "$@"
}

# sftp_violations FILE...: lines of the SFTP compose template (templates/sftp.compose.yml) or of the file generated from it that go
# beyond its stated exceptions. It publishes one port, "ADDRESS:2222:22" (ADDRESS: 127.0.0.1, 0.0.0.0 or the placeholder
# {{SFTP_BIND}}), adds the capabilities CHOWN, SETGID, SETUID, DAC_OVERRIDE and SYS_CHROOT (sshd's chroot), and nothing else. Flagged:
# a second or another published port; privileged, pid, userns_mode, devices or network_mode; any other cap_add; the Docker socket;
# a credential written as a plain value (a key or KEY= entry named *PASSWORD, *PASSWD, *SECRET, *TOKEN or *_KEY; the *_FILE form is
# fine); and a $ anywhere, comments too (a $ in a generated compose file is a variable for compose to fill in).
sftp_violations() {
    (($# > 0)) || return 0
    awk '
        function bad() { if (!seen[FILENAME, FNR]++) print FILENAME ":" FNR ": " $0 }
        FNR == 1 { inports = 0; n = 0 }
        /[$]/ { bad() }
        /^[ \t]*#/ { next }
        inports && /^[ \t]*-/ { if ($0 !~ /^[ \t]*-[ \t]*"(127\.0\.0\.1|0\.0\.0\.0|\{\{SFTP_BIND\}\}):2222:22"[ \t]*(#.*)?$/ || ++n > 1) bad(); next }
        { inports = 0 }
        /^[ \t]*ports:/ { inports = 1; if ($0 !~ /^[ \t]*ports:[ \t]*(#.*)?$/) bad() }
        /^[ \t]*(privileged|pid|userns_mode|devices|network_mode):/ { bad() }
        /^[ \t]*cap_add:/ && $0 !~ /^[ \t]*cap_add:[ \t]*\[[ \t]*CHOWN,[ \t]*SETGID,[ \t]*SETUID,[ \t]*DAC_OVERRIDE,[ \t]*SYS_CHROOT[ \t]*\][ \t]*(#.*)?$/ { bad() }
        /docker\.sock/ { bad() }
        /^[ \t]*(- *)?"?[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)(:|=)/ { bad() }' "$@"
}

# curl_violations FILE...: non-comment lines that run curl (curl followed by an option) anywhere but lib/cloudflare.sh, or without
# -q first (no ~/.curlrc) and --config - (the token comes from stdin), or with credential material on the line (Authorization, Bearer, --oauth2-bearer, --user,
# -u, a variable or word with "tok" in it)
curl_violations() {
    local l f t
    (($# > 0)) || return 0
    grep -nHE '(^|[^[:alnum:]_.-])curl[[:space:]]+-' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' |
        while IFS= read -r l; do
            f=${l%%:*} t=${l#*:*:}
            if [[ $f != cloudflare.sh && $f != */cloudflare.sh || $t != *"--config -"* || $t != *"curl -q "* ]] || [[ $t =~ Authorization|Bearer|oauth2|--user|[[:space:]]-u[[:space:]]|tok ]]; then
                printf '%s\n' "$l"
            fi
        done
}

# bearer_violations FILE...: non-comment lines that name a bearer token other than by printing the curl config line
# header = "Authorization: Bearer %s" (which goes to curl's stdin)
bearer_violations() {
    (($# > 0)) || return 0
    grep -nHiE 'bearer' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' |
        grep -vF "printf 'header = \"Authorization: Bearer %s\"\\n' \"\$tok\" |"
}

# token_file_violations FILE...: non-comment lines outside lib/cloudflare.sh that name the token file (it is read in one place)
token_file_violations() {
    (($# > 0)) || return 0
    grep -nHE 'cloudflare_token|CLOUDFLARE_TOKEN_SECRET' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' |
        grep -Ev '^([^:]*/)?cloudflare\.sh:'
}

# proxied_violations FILE...: non-comment lines that set "proxied" to anything but false (a game-port record is DNS-only)
proxied_violations() {
    (($# > 0)) || return 0
    grep -nHE 'proxied' -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' |
        grep -vE '"?proxied"?[[:space:]]*:[[:space:]]*false([^[:alnum:]_]|$)'
}

# --- the rules against fixtures ---------------------------------------------------------------------------------------------
echo "rules fire on bad input"
FXD=$(mktemp -d) || exit 1
mkdir -p "$FXD/lib" "$FXD/tests" "$FXD/cr"

cat >"$FXD/words.sh" <<'EOF'
eval "$x"
# eval in a comment
sudo ufw allow 25565
retrieval=1; echo evaluate
y=$(eval foo)
EOF
lines() { cut -d: -f2 | paste -sd, -; }   # the line numbers of "file:N:text" hits
assert_eq "1,5" "$(cd "$FXD" && scan_word eval words.sh | lines)" "scan_word finds eval, not a comment or a longer word"
assert_eq "3"   "$(cd "$FXD" && scan_word sudo words.sh | lines)" "scan_word finds sudo"

cat >"$FXD/rm.sh" <<'EOF'
rm -rf "$dir"
: separator
rm -fr "$dir" && echo "$x"
: separator
rm -r -f -- "$dir"
: separator
safe_path "$p" && rm -rf -- "$p"
: separator
valid_server_name "$n" || return 1
rm -rf -- "$d"
: separator
rm -rf /tmp/mcctl-fixed
: separator
rm -f "$x"
: separator
find "$d" -name x | xargs rm -rf
find "$d" -name y -exec rm -rf {} +
EOF
assert_eq "1,3,5,16,17" "$(cd "$FXD" && rm_rf_unguarded rm.sh | lines)" "rm_rf_unguarded flags computed unguarded targets only"

printf 'ok\n' >"$FXD/cr/clean.sh"; printf 'bad\r\n' >"$FXD/cr/crlf.sh"
assert_eq "$FXD/cr/crlf.sh" "$(files_with_cr "$FXD/cr")" "files_with_cr finds the CRLF file only"

printf '%s\n' 'cmd_alpha() { :; }' 'function cmd_beta { :; }' 'cmd_gamma_x() { :; }' 'helper() { :; }' >"$FXD/lib/a.sh"
printf '%s\n' 'cmd_alpha' '# covers cmd_gamma_x' >"$FXD/tests/t_a.sh"
printf '%s\n' 'cmd_beta cmd_alpha' >"$FXD/tests/t_invariants.sh"
assert_eq "cmd_beta" "$(untested_cmds "$FXD/lib" "$FXD/tests")" "untested_cmds names the command no t_*.sh mentions (this file does not count)"

cat >"$FXD/env.sh" <<'EOF'
source config/mcctl.env
. "$dir/server.env"
source "$MCCTL_HOME/lib/x.sh"
# source a.env in a comment
load_envfile config/mcctl.env
x=1; . ./y.env
source /etc/profile.d/some.environment
echo "see mcctl.env"
EOF
assert_eq "1,2,6" "$(cd "$FXD" && sources_env env.sh | lines)" "sources_env finds source/. of an .env file, not a comment, a parser call or a longer word"
cat >"$FXD/tmpl.yaml" <<'EOF'
ports:
    - "25565:25565"
  privileged: true
      RCON_PASSWORD: "x"
      RCON_PASSWORD_FILE: "/run/secrets/rcon_password"
      - "mcctl.managed=true"
      network_mode: host
# ports: in a comment
      - API_TOKEN=abc
      CF_API_KEY_FILE: "/run/secrets/cf"
    network_mode: "service:mc"
    network_mode: "service:other"
    network_mode: "container:x"
EOF
assert_eq "1,3,4,7,9,12,13" "$(cd "$FXD" && template_violations tmpl.yaml | lines)" "template_violations flags published ports, host access, any network_mode but \"service:mc\" and plain credentials, not *_FILE or comments"
cat >"$FXD/cfkey.sh" <<'EOF'
echo "CF_API_KEY=$k"
extra+='      CF_API_KEY_FILE: "/run/secrets/cf_api_key"'
# CF_API_KEY in a comment
x="$CF_API_KEY"
extra+='      CF_API_KEY: "x"'
EOF
assert_eq "1,4,5" "$(cd "$FXD" && plain_cf_key cfkey.sh | lines)" "plain_cf_key flags CF_API_KEY= / : / a variable of that name, not CF_API_KEY_FILE or a comment"
cat >"$FXD/rconpw.sh" <<'EOF'
docker exec -i "$c" rcon-cli "$@"
docker exec -i "$c" rcon-cli --password "$pw" say hi
docker exec -e RCON_PASSWORD="$pw" "$c" rcon-cli list
docker exec "$c" rcon-cli -p "$pw" list
# rcon-cli --password in a comment
docker exec -it "$c" rcon-cli
docker exec "$c" rcon-cli -p=x list
die "rcon-cli failed on $name (see above)"
EOF
assert_eq "2,3,4,7" "$(cd "$FXD" && rcon_password_argv rconpw.sh | lines)" "rcon_password_argv flags a password option or variable next to rcon-cli, not a comment or a clean call"
cat >"$FXD/stack.yaml" <<'EOF'
services:
  a:
    privileged: true
    network_mode: host
    network_mode: bridge
    cap_add: [NET_ADMIN]
    cap_add: [NET_ADMIN, SYS_ADMIN]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - "/var/run/docker.sock:/var/run/docker.sock"
      - /var/run/docker.sock:/var/run/docker.sock:rw
    ports:
      - "25565:25565"
      - "8080:80"
    environment:
      # ports:
      API_TOKEN: x
      API_TOKEN_FILE: /x
      MC_KEY=abc
    devices:
      - /dev/net/tun
  b:
    ports: ["80:80"]
    ports:
      - "25565:25565"
    pid: host
EOF
assert_eq "3,5,7,10,11,14,17,19,20,23,25,26" "$(cd "$FXD" && stack_violations stack.yaml | lines)" "stack_violations flags what the router stack may not do (privileged, other network_mode or cap_add, other or repeated ports, a socket without :ro, a plain credential, devices, pid), not the allowed lines or comments"
cat >"$FXD/lib/cloudflare.sh" <<'EOF'
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" |
        curl -q -sS --proto =https --max-time 30 --config - -X "$method" "$url")
curl -q -sS -H "Authorization: Bearer $tok" "$url"
curl -q -sS "$url"
curl -q -sS --config - -u "user:$pw" "$url"
curl -sS --config - --oauth2-bearer "$t" "$url"
# curl -sS -H "Authorization: Bearer x" in a comment
doctor_need curl "install the 'curl' package"
curl -q -sS --config - -X GET "$url?token=$CF"
local f=$MCCTL_ROOT/secrets/$CLOUDFLARE_TOKEN_SECRET
    '{type: "A", proxied: false, ttl: 120}'
curl -sS --config - -X GET "$url"
EOF
cat >"$FXD/lib/other.sh" <<'EOF'
curl -sS --config - -X GET "$url"
echo "Bearer $t" >&2
cat "$MCCTL_ROOT/secrets/cloudflare_token"
# secrets/cloudflare_token in a comment
body='{"proxied": true}'
jq -n '{proxied: $p}'
x='{"proxied":false}'
EOF
assert_eq "3,4,5,6,9,12" "$(cd "$FXD" && curl_violations lib/cloudflare.sh | lines)" "curl_violations flags a curl without --config -, with an Authorization header, -u, --oauth2-bearer or a token on its line, or without -q first, not the stdin-config call, a comment or a word curl"
assert_eq "1" "$(cd "$FXD" && curl_violations lib/other.sh | lines)" "curl_violations flags any curl outside lib/cloudflare.sh"
assert_eq "3,6" "$(cd "$FXD" && bearer_violations lib/cloudflare.sh | lines)" "bearer_violations flags a bearer token anywhere but the printf into curl's stdin, not a comment"
assert_eq "2" "$(cd "$FXD" && bearer_violations lib/other.sh | lines)" "bearer_violations flags an echo of a bearer token"
assert_eq "" "$(cd "$FXD" && token_file_violations lib/cloudflare.sh | lines)" "token_file_violations allows lib/cloudflare.sh to name the token file"
assert_eq "3" "$(cd "$FXD" && token_file_violations lib/other.sh | lines)" "token_file_violations flags another file that reads it, not a comment"
assert_eq "5,6" "$(cd "$FXD" && proxied_violations lib/other.sh | lines)" "proxied_violations flags proxied true or a variable, not proxied false"
assert_eq "" "$(cd "$FXD" && proxied_violations lib/cloudflare.sh | lines)" "proxied_violations passes proxied: false"
cat >"$FXD/sftp_bad.yaml" <<'EOF'
ports:
  - "127.0.0.1:2222:22"
  - "0.0.0.0:2222:22"
cap_add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE, SYS_CHROOT]
cap_add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE, SYS_CHROOT, NET_ADMIN]
ports: ["2222:22"]
privileged: true
network_mode: host
  - /var/run/docker.sock:/var/run/docker.sock:ro
  - "/srv/$HOME:/x"
# a comment with $ in it
      API_TOKEN: x
      SFTP_PASSWORD_FILE: /x
  - "/data/ok:/home/a/a"
ports:
  - "0.0.0.0:22:22"
EOF
assert_eq "3,5,6,7,8,9,10,11,12,16" "$(cd "$FXD" && sftp_violations sftp_bad.yaml | lines)" "sftp_violations flags a second or other port, another cap_add, host access, the socket, a \$ (comments too) and a plain credential, not *_FILE or an ordinary mount"
printf '%s\n' 'services:' '  sftp:' '    ports:' '      - "{{SFTP_BIND}}:2222:22"   # the placeholder' '    cap_add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE, SYS_CHROOT]' '# no variable here' >"$FXD/sftp_ok.yaml"
printf '%s\n' 'ports:' '  - "0.0.0.0:2222:22"' >"$FXD/sftp_pub.yaml"
assert_eq "" "$(cd "$FXD" && sftp_violations sftp_ok.yaml sftp_pub.yaml | lines)" "sftp_violations passes the placeholder, 127.0.0.1 and 0.0.0.0 as the one port (the count starts again in each file)"
rm -rf -- "$FXD"

# --- the rules against the tree --------------------------------------------------------------------------------------------
echo "syntax"
mapfile -t SH < <({ find . -type f -name '*.sh' -not -path './docs/*'; echo mcctl; ls tests/fakebin/*; } | sed 's|^\./||' | sort -u)
for f in "${SH[@]}"; do
    [[ -f $f ]] || { fail "bash -n $f" "no such file"; continue; }
    bash -n "$f" 2>/dev/null && pass "bash -n $f" || fail "bash -n $f"
done

echo "eval, sudo"
mapfile -t CODE < <({ echo mcctl; find lib templates -type f 2>/dev/null; echo tests/lib.sh; echo tests/run.sh; ls tests/fakebin/*; } | sort -u)
for w in eval sudo; do
    hits=$(scan_word "$w" "${CODE[@]}")
    assert_eq "" "$hits" "no $w in mcctl, lib/, templates/ or the test infrastructure"
done

echo "rm -rf"
mapfile -t LIBSH < <(find lib -type f -name '*.sh' 2>/dev/null | sort)
assert_eq "" "$(rm_rf_unguarded "${LIBSH[@]}")" "every recursive rm in lib/ is guarded by safe_path/valid_server_name or has a literal target"

echo "compose templates"
mapfile -t TMPL < <(find templates -type f ! -name stack.compose.yml ! -name sftp.compose.yml 2>/dev/null | sort)
assert_eq "" "$(template_violations "${TMPL[@]}")" "no server template publishes a port, opens the host or writes a credential as a plain value"
[[ -f templates/stack.compose.yml ]] && pass "templates/stack.compose.yml exists" || fail "templates/stack.compose.yml exists"
assert_eq "" "$(stack_violations templates/stack.compose.yml)" "the router stack template has only its stated exceptions (host network and NET_ADMIN for the guard, port 25565 once, the socket :ro)"
assert_eq 0 "$(grep -ci 'sftp\|2222' templates/stack.compose.yml)" "the router stack template has no SFTP and no port 2222 (SFTP is its own project)"
[[ -f templates/sftp.compose.yml ]] && pass "templates/sftp.compose.yml exists" || fail "templates/sftp.compose.yml exists"
assert_eq "" "$(sftp_violations templates/sftp.compose.yml)" "the SFTP template has one published port (2222 to 22), its stated capabilities, no socket, no plain credential and no \$"
SFD=$(mktemp -d) || exit 1
mkdir -p "$SFD/servers/a/data" "$SFD/sftp-keys"
printf 'a::1000:1000:a\n' >"$SFD/sftp-users.conf"; printf 'ssh-ed25519 AAAA k\n' >"$SFD/sftp-keys/a"
for pub in 0 1; do
    # sftp_render calls no docker; the stub makes sure of it
    ( source lib/common.sh && source lib/compose.sh && source lib/sftp.sh && docker() { return 99; } && MCCTL_ROOT=$SFD MCCTL_SFTP_PUBLIC=$pub sftp_render ) >/dev/null 2>&1 \
        && pass "sftp_render writes the file (MCCTL_SFTP_PUBLIC=$pub)" || fail "sftp_render writes the file (MCCTL_SFTP_PUBLIC=$pub)"
    assert_eq "" "$(sftp_violations "$SFD/sftp.compose.yml")" "the generated SFTP file passes the same rule (MCCTL_SFTP_PUBLIC=$pub): one port, no \$"
    want=127.0.0.1; ((pub)) && want=0.0.0.0
    grep -qxF "      - \"$want:2222:22\"" "$SFD/sftp.compose.yml" && pass "and publishes it on $want" || fail "and publishes it on $want"
done
rm -rf -- "$SFD"

echo "configuration is parsed, not sourced"
mapfile -t SRC < <({ echo mcctl; find lib templates -type f 2>/dev/null; } | sort)
assert_eq "" "$(sources_env "${SRC[@]}")" "nothing in mcctl, lib/ or templates/ sources an .env file"

echo "the CurseForge API key"
assert_eq "" "$(plain_cf_key "${SRC[@]}")" "nothing in mcctl, lib/ or templates/ names the key other than as CF_API_KEY_FILE"

echo "RCON"
assert_eq "" "$(rcon_password_argv "${SRC[@]}")" "no line in mcctl, lib/ or templates/ puts a password next to rcon-cli"

echo "Cloudflare: the token and the records"
assert_eq "" "$(curl_violations "${SRC[@]}")" "curl runs only in lib/cloudflare.sh, with -q first (no ~/.curlrc), --config - and no credential on its line"
assert_eq "" "$(bearer_violations "${SRC[@]}")" "the bearer token is only printed into curl's stdin"
assert_eq "" "$(token_file_violations "${SRC[@]}")" "only lib/cloudflare.sh names the token file"
assert_eq "" "$(proxied_violations "${SRC[@]}")" "every DNS record is written proxied: false"
assert_eq 1 "$(grep -c '^ *curl -q -sS --proto =https --max-time 30 --config - -X' lib/cloudflare.sh)" "(lib/cloudflare.sh has its one curl call, so the rules above had something to check)"
grep -qx '/trash/' .gitignore && pass ".gitignore keeps /trash/ (deleted servers' archives) out of git" || fail ".gitignore keeps /trash/ out of git"

echo "line endings"
mapfile -t DIRS < <(printf '%s\n' mcctl lib tests templates | while read -r d; do [[ -e $d ]] && echo "$d"; done)
assert_eq "" "$(files_with_cr "${DIRS[@]}")" "no CR byte in mcctl, lib/, tests/, templates/"

echo "tests for commands"
assert_eq "" "$(untested_cmds lib tests)" "every cmd_* function in lib/ is named in a tests/t_*.sh"

echo "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    out=$(shellcheck -x --severity=warning "${SH[@]}" 2>&1)
    assert_eq "" "$out" "shellcheck (warning and above) is clean"
else
    skip "shellcheck is not installed"
fi

finish

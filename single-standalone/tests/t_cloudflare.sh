#!/usr/bin/env bash
# lib/cloudflare.sh (fqdn_for, cf_api, cf_create_record, cf_delete_record, cf_delete_server) and the order of create and delete
# around it (Review Focus 2), including the archive delete writes first. fakebin/curl plays the Cloudflare API, a state machine
# over $FAKE_STATE/curl.records.json; dns_records (tests/lib.sh) reads that state. E1: ordered call logs. E4: the token, a canary,
# reaches curl on stdin and never appears in an argument list, the call log or any output. E11: the archive is written beside its
# final name and moved into place; a failing tar leaves nothing. Nothing here needs a network: the fakes answer every call.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; rm -f "$FAKE_STATE"/curl.*.rc "$FAKE_STATE"/curl.*.body "$FAKE_STATE"/docker.*.rc "$FAKE_STATE/mutations"; }
ALL=""                                       # every output, searched for the token at the end (E4)
run() { m "$@"; ALL+=$OUT$'\n'; }
fn() { OUT=$("$@" 2>"$SB/err"); RC=$?; ERR=$(<"$SB/err"); ALL+=$OUT$'\n'$ERR$'\n'; }   # a library function, in this shell
API=https://api.cloudflare.com/client/v4/zones/$MCCTL_CF_ZONE_ID/dns_records
CURL="curl -q -sS --proto =https --max-time 30 --config -"
H="-H Content-Type: application/json"
GET()    { echo "$CURL -X GET $H $API?$1"; }
DELETE() { echo "$CURL -X DELETE $H $API/$1"; }
POSTED() { calls | grep -c -- "-X POST"; }
DB=$FAKE_STATE/curl.records.json
seed() { printf '%s\n' "$1" >"$DB"; }       # seed JSON-ARRAY: the zone's records, as Cloudflare would have them
zone() { jq -cS . "$DB" | tr -d '\r'; }     # the zone, normalised, to compare before and after
REC='.[] | [.type, .name, .content, (.proxied | tostring), (.ttl | tostring), (.comment // "none")] | join(" ")'
# no signal goes to mc-router in these flows: it follows Docker's events (lib/router.sh)
dcl() { echo "docker compose -p mcctl-$1 -f $SB/servers/$1/compose.yaml $2"; }

echo "fqdn_for"
assert_eq "play.mc.example.net" "$(fqdn_for play)" "fqdn_for HOST is HOST.MCCTL_DOMAIN"

echo "cf_api: the token reaches curl on stdin, never as an argument (E4)"
reset
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records?name=x.mc.example.net"
assert_eq 0 "$RC" "cf_api GET: 0 when Cloudflare answers success"
assert_contains "$OUT" '"success":true' "and the answer is on stdout"
assert_eq "$(GET name=x.mc.example.net)" "$(calls)" "one curl call: HTTPS only, 30 s, the config (with the token) from stdin, the method, the URL"
assert_not_contains "$(calls)" "$CF_TOKEN" "the token is not in the argument list"
assert_not_contains "$(calls)" "Authorization" "and neither is an Authorization header"
assert_eq "$CF_TOKEN" "$(<"$FAKE_STATE/curl.bearer")" "curl received it on stdin, as the bearer token of the Authorization header"
echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}' >"$FAKE_STATE/curl.GET.body"
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records"
assert_eq 1 "$RC" "an answer with success false: 1"
assert_contains "$ERR" "10000 Authentication error" "the message gives Cloudflare's reason"
assert_eq "" "$OUT" "and nothing is printed on stdout"
reset; echo '<html>502 Bad Gateway</html>' >"$FAKE_STATE/curl.GET.body"
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records"
assert_eq 1 "$RC" "an answer that is not JSON: 1"
reset; echo 7 >"$FAKE_STATE/curl.GET.rc"
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records"
assert_eq 1 "$RC" "curl fails (no network): 1"
assert_contains "$ERR" "could not be reached" "and it says so"
reset
printf 'abc"\noutput = /tmp/x\n' >"$SB/secrets/cloudflare_token"
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records"
assert_eq 3 "$RC" "a token file with a quote and a second line: EX_PREFLIGHT (it could add a line to curl's config)"
assert_eq "" "$(calls)" "and curl is not called"
assert_not_contains "$ERR" "output = " "the message does not echo the file"
printf 'tok-123_ABC\r\n' >"$SB/secrets/cloudflare_token"
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records"
assert_eq 0 "$RC" "a token written with a Windows line end is accepted"
assert_eq "tok-123_ABC" "$(<"$FAKE_STATE/curl.bearer")" "without the CR"
rm -f "$SB/secrets/cloudflare_token"; reset
fn cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records"
assert_eq 3 "$RC" "no token file: EX_PREFLIGHT"
assert_contains "$ERR" "secrets/cloudflare_token" "the message names the file"
assert_eq "" "$(calls)" "and curl is not called"
fake_cloudflare   # a fresh token canary

echo "cf_create_record"
reset
fn cf_create_record play s1
assert_eq 0 "$RC" "cf_create_record play s1"
[[ $OUT =~ ^rec[0-9]+$ ]] && pass "prints the id of the new record ($OUT)" || fail "prints the record id" "$OUT"
assert_eq "A play.mc.example.net 203.0.113.7 false 120 mcctl name=s1" "$(dns_records "$REC")" "type A, the public IPv4, proxied false, ttl 120, comment 'mcctl name=s1'"
assert_eq "$(GET name=play.mc.example.net)
$CURL -X POST $H --data {\"type\":\"A\",\"name\":\"play.mc.example.net\",\"content\":\"203.0.113.7\",\"ttl\":120,\"proxied\":false,\"comment\":\"mcctl name=s1\"} $API" "$(calls)" \
    "calls: look the name up, then one POST"
body=$(calls | sed -n 's/.* --data \(.*\) https:.*/\1/p')
assert_eq "true" "$(jq -r '.proxied == false and .content == "203.0.113.7" and .type == "A"' <<<"$body" | tr -d '\r')" "the request body has \"proxied\": false and the configured public IPv4"
assert_not_contains "$(calls)" "$CF_TOKEN" "the token is in no argument list (E4)"
fn cf_create_record solo
assert_eq "mcctl name=solo" "$(dns_records '.[] | select(.name == "solo.mc.example.net") | .comment')" "NAME defaults to HOST"

echo "cf_create_record never overwrites"
FOREIGN='[{"id":"f1","type":"A","name":"web.mc.example.net","content":"198.51.100.1","proxied":true,"ttl":1,"comment":null},
          {"id":"f2","type":"CNAME","name":"www.mc.example.net","content":"web.mc.example.net","proxied":true,"ttl":1,"comment":"terraform"},
          {"id":"f3","type":"A","name":"old.mc.example.net","content":"203.0.113.7","proxied":false,"ttl":120,"comment":"mcctl name=gone"}]'
seed "$FOREIGN"; before=$(zone)
for h in web www; do
    reset
    fn cf_create_record "$h" s2
    assert_eq 4 "$RC" "a record named $h.mc.example.net that mcctl did not make: EX_REFUSED"
    assert_eq "$(GET name=$h.mc.example.net)" "$(calls)" "$h: it was looked up and nothing was written (no POST)"
    assert_contains "$ERR" "$h.mc.example.net" "$h: the message names the record"
    assert_contains "$ERR" "mcctl leaves it as it is" "$h: and says it is left alone"
done
assert_contains "$ERR" '"terraform"' "the record's own comment is shown, quoted"
reset
fn cf_create_record old s2
assert_eq 4 "$RC" "a record mcctl made earlier (comment mcctl name=gone): EX_REFUSED too"
assert_contains "$ERR" "mcctl delete" "and the message says how to remove it"
assert_eq 0 "$(POSTED)" "no POST"
assert_eq "$before" "$(zone)" "the zone is exactly as it was"
reset; echo 7 >"$FAKE_STATE/curl.GET.rc"
fn cf_create_record fresh s2
assert_eq 1 "$RC" "the look-up fails: 1"
assert_eq 0 "$(POSTED)" "and nothing is posted"
reset; echo '{"success":false,"errors":[{"code":81053,"message":"An A, AAAA, or CNAME record with that host already exists."}]}' >"$FAKE_STATE/curl.POST.body"
fn cf_create_record fresh s2
assert_eq 1 "$RC" "Cloudflare refuses the POST: 1"
assert_contains "$ERR" "81053" "with Cloudflare's reason"
assert_eq "$before" "$(zone)" "nothing was made"
reset
FAIL_AT=1 fn cf_create_record late s2
assert_eq 1 "$RC" "the POST times out after Cloudflare made the record (FAIL_AT=1): 1"
assert_eq "$before" "$(zone)" "and the record it made is deleted again: no orphan"
assert_eq "$(GET name=late.mc.example.net)
$CURL -X POST $H --data {\"type\":\"A\",\"name\":\"late.mc.example.net\",\"content\":\"203.0.113.7\",\"ttl\":120,\"proxied\":false,\"comment\":\"mcctl name=s2\"} $API
$(GET name=late.mc.example.net)
$(DELETE rec3)" "$(calls)" "calls: look up, POST, look up again, DELETE what the POST made"

echo "cf_delete_record"
reset
fn cf_delete_record web
assert_eq 0 "$RC" "a record mcctl did not make: 0 (there is no mcctl record to delete)"
assert_eq "$(GET name=web.mc.example.net)" "$(calls)" "and no DELETE was sent"
assert_contains "$ERR" "left alone: A web.mc.example.net" "it names the record it left alone"
assert_eq "$before" "$(zone)" "the zone is unchanged"
reset
fn cf_delete_record nothere
assert_eq 0 "$RC" "a record that does not exist: 0 (idempotent)"
assert_eq "$(GET name=nothere.mc.example.net)" "$(calls)" "one look-up, no DELETE"
seed '[{"id":"m1","type":"A","name":"mix.mc.example.net","content":"203.0.113.7","comment":"mcctl name=mix"},
       {"id":"t1","type":"TXT","name":"mix.mc.example.net","content":"v=spf1 -all","comment":null}]'
reset
fn cf_delete_record mix
assert_eq 0 "$RC" "a name with an mcctl record and a foreign TXT record"
assert_eq "mix.mc.example.net null" "$(dns_records '.[] | "\(.name) \(.comment)"')" "only the mcctl record is deleted"
assert_eq "$(GET name=mix.mc.example.net)
$(DELETE m1)" "$(calls)" "calls: look up, DELETE m1 (never t1)"
seed '[{"id":"m2","type":"A","name":"stuck.mc.example.net","content":"203.0.113.7","comment":"mcctl name=stuck"}]'
reset; echo 7 >"$FAKE_STATE/curl.DELETE.rc"
fn cf_delete_record stuck
assert_eq 1 "$RC" "the DELETE fails: 1"
assert_contains "$ERR" "could not delete the DNS record stuck.mc.example.net" "the warning names the record"
assert_eq 1 "$(dns_records '.[] | .id' | grep -c m2)" "and the record is still there"
reset
fn cf_delete_record stuck
assert_eq 0 "$RC" "run again once Cloudflare answers: 0"
assert_eq "" "$(dns_records)" "the record is gone"
fn cf_delete_record 'a/b'; assert_eq 2 "$RC" "a host that cannot be a DNS label: EX_USAGE"
seed '[{"id":"n1","type":"A","name":"both.mc.example.net","content":"203.0.113.7","comment":"mcctl name=other"},
       {"id":"n2","type":"A","name":"both.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s1"}]'
reset
fn cf_delete_record both s1
assert_eq 0 "$RC" "cf_delete_record HOST NAME"
assert_eq "both.mc.example.net mcctl name=other" "$(dns_records)" "deletes only the record whose comment is exactly 'mcctl name=s1', not another server's mcctl record"
assert_eq "$(GET name=both.mc.example.net)
$(DELETE n2)" "$(calls)" "calls: look up, DELETE n2 only"
assert_contains "$ERR" "left alone: A both.mc.example.net" "and it names the record it left"

echo "cf_delete_server"
seed '[{"id":"a1","type":"A","name":"s9.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s9"},
       {"id":"a2","type":"A","name":"play9.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s9"},
       {"id":"a3","type":"A","name":"s9.other.example.org","content":"192.0.2.1","comment":"mcctl name=s9"},
       {"id":"a4","type":"A","name":"s9x.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s9x"},
       {"id":"a5","type":"A","name":"up.mc.example.net","content":"203.0.113.7","comment":"MCCTL NAME=S9"},
       {"id":"a6","type":"A","name":"a.b.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s9"}]'
reset
cf_delete_server s9 2>"$SB/err"; rc=$?
assert_eq 0 "$rc" "cf_delete_server s9"
assert_eq 2 "$CF_FOUND" "it found the two hosts of s9 under MCCTL_DOMAIN"
assert_eq "a.b.mc.example.net mcctl name=s9
s9.other.example.org mcctl name=s9
s9x.mc.example.net mcctl name=s9x
up.mc.example.net MCCTL NAME=S9" "$(dns_records)" "and deleted those two only: not another domain's, not s9x's, not a comment that only matches without case, not a name two labels deep"
assert_eq "$(GET 'comment.exact=mcctl%20name%3Ds9')
$(DELETE a1)
$(DELETE a2)" "$(calls)" "calls: one look-up by comment, then a DELETE by id of each record that passed the check"
echo "-- Cloudflare answers every record, as if it ignored the comment filter: the check on its answer still holds"
seed '[{"id":"a1","type":"A","name":"s9.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s9"},
       {"id":"a7","type":"A","name":"s9.mc.example.net","content":"203.0.113.7","comment":"mcctl name=other"},
       {"id":"a8","type":"TXT","name":"s9.mc.example.net","content":"x","comment":null},
       {"id":"a9","type":"A","name":"s9.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s9 and more"}]'
reset
jq -c '{success: true, errors: [], result: .}' "$DB" >"$FAKE_STATE/curl.GET.body"
cf_delete_server s9 2>"$SB/err"; rc=$?
assert_eq "0 1" "$rc $CF_FOUND" "only one record has the comment exactly 'mcctl name=s9'"
assert_eq "s9.mc.example.net mcctl name=other
s9.mc.example.net mcctl name=s9 and more
s9.mc.example.net null" "$(dns_records)" "another server's record, a longer comment and a foreign record at the same name are left"
assert_eq "$(GET 'comment.exact=mcctl%20name%3Ds9')
$(DELETE a1)" "$(calls)" "calls: the look-up, then DELETE a1 only"
reset
cf_delete_server nobody 2>/dev/null; rc=$?
assert_eq "0 0" "$rc $CF_FOUND" "a server with no record: 0, and CF_FOUND is 0"
echo 7 >"$FAKE_STATE/curl.GET.rc"
cf_delete_server s9 2>"$SB/err"; rc=$?
assert_eq 1 "$rc" "Cloudflare cannot be asked: 1"
assert_contains "$(<"$SB/err")" "could not ask Cloudflare for the DNS records of s9" "and it says so"

echo "create: the DNS record comes first, and is taken back"
seed '[]'; rm -f "$FAKE_STATE/curl.ids"; reset   # record ids start again at rec1
run create s1 --type PAPER --accept-eula --hostname play
assert_eq 0 "$RC" "create s1 --hostname play"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker ps -a -q --filter label=mcctl.hostname=play
$(GET name=play.mc.example.net)
$CURL -X POST $H --data {\"type\":\"A\",\"name\":\"play.mc.example.net\",\"content\":\"203.0.113.7\",\"ttl\":120,\"proxied\":false,\"comment\":\"mcctl name=s1\"} $API
$(give_line "$SB/servers/s1/data")
$(give_line "$SB/servers/s1/backups" 755)
$(give_line "$SB/secrets/rcon-s1.TMP")
$(sftp_ps_call)
$(dcl s1 create)" "$(calls)" "calls: Docker checks, the DNS record, the game's user is given data and the secret, is SFTP running, compose create"
assert_eq 0 "$(count_calls 'kill -s HUP')" "create sends no router signal"
assert_eq "play.mc.example.net mcctl name=s1" "$(dns_records)" "the record is there, with the server's name in its comment"
fake_server s1 play
reset; echo 7 >"$FAKE_STATE/curl.POST.rc"
run create s2 --type PAPER --accept-eula
assert_eq 1 "$RC" "the Cloudflare API fails the create call: create exits non-zero"
assert_eq 0 "$(count_calls 'compose -p mcctl-s2')" "and docker compose ... create was not called"
assert_no_file "$SB/servers/s2" "no folder was written"
assert_no_file "$SB/secrets/rcon-s2" "no secret"
assert_eq "play.mc.example.net mcctl name=s1" "$(dns_records)" "and no record was made"
seed "$(jq -c '. + [{"id":"f9","type":"A","name":"s2.mc.example.net","content":"198.51.100.9","comment":null}]' "$DB")"
reset
run create s2 --type PAPER --accept-eula
assert_eq 4 "$RC" "a record not made by mcctl at the server's name: EX_REFUSED"
assert_eq 00 "$(POSTED)$(count_calls 'compose -p mcctl-s2')" "no POST, no compose call"
assert_no_file "$SB/servers/s2" "nothing written"
seed "$(jq -c 'map(select(.id != "f9"))' "$DB")"
reset; echo 1 >"$FAKE_STATE/docker.compose.create.rc"
run create s2 --type PAPER --accept-eula
assert_eq 1 "$RC" "the container create fails after the DNS record was made: EX_FAIL"
assert_eq "play.mc.example.net mcctl name=s1" "$(dns_records)" "the DNS record is deleted again"
assert_no_file "$SB/servers/s2" "the folder is gone"
assert_no_file "$SB/secrets/rcon-s2" "and the secret"
assert_eq "docker ps -a -q --filter label=mcctl.name=s2
docker ps -a -q --filter label=mcctl.hostname=s2
$(GET name=s2.mc.example.net)
$CURL -X POST $H --data {\"type\":\"A\",\"name\":\"s2.mc.example.net\",\"content\":\"203.0.113.7\",\"ttl\":120,\"proxied\":false,\"comment\":\"mcctl name=s2\"} $API
$(give_line "$SB/servers/s2/data")
$(give_line "$SB/servers/s2/backups" 755)
$(give_line "$SB/secrets/rcon-s2.TMP")
$(sftp_ps_call)
$(dcl s2 create)
$(dcl s2 'rm -s -f')
$(GET name=s2.mc.example.net)
$(DELETE rec2)
$(sftp_ps_call)
$(clear_line "$SB/servers/s2")" "$(calls)" "calls: DNS, the game's user is given data and the secret, SFTP, compose create, then in reverse: the containers, the DNS record, the SFTP user, the game's data"
assert_eq 0 "$(count_calls 'kill -s HUP')" "no router signal for a create that did not happen"
reset; echo 1 >"$FAKE_STATE/docker.compose.create.rc"; echo 7 >"$FAKE_STATE/curl.DELETE.rc"
run create s2 --type PAPER --accept-eula
assert_eq 1 "$RC" "compose create fails, and so does the DNS clean-up: EX_FAIL"
assert_contains "$OUT" "the DNS record s2.mc.example.net is left over: run 'mcctl delete s2'" "the warning names the record and the way out"
assert_no_file "$SB/servers/s2" "the folder still goes (its containers are gone)"
reset
run --yes delete s2
assert_eq 0 "$RC" "mcctl delete s2 removes the left-over record"
assert_eq "docker ps -a -q --filter label=mcctl.name=s2
$(GET 'comment.exact=mcctl%20name%3Ds2')
$(DELETE rec3)" "$(calls)" "calls: no container, no folder: only the DNS look-up and the DELETE"
assert_contains "$OUT" "only its DNS record was left, and it is removed" "and it says what it did"
assert_eq "play.mc.example.net mcctl name=s1" "$(dns_records)" "and only s1's record is left"
MCCTL_PUBLIC_IPV4= run create s3 --type PAPER --accept-eula
assert_eq 3 "$RC" "create without MCCTL_PUBLIC_IPV4: EX_PREFLIGHT"; assert_contains "$OUT" "MCCTL_PUBLIC_IPV4" "named"
mv "$SB/secrets/cloudflare_token" "$SB/tok"; reset
run create s3 --type PAPER --accept-eula
assert_eq 3 "$RC" "create without the token file: EX_PREFLIGHT"
assert_eq "" "$(calls)" "before any call"
mv "$SB/tok" "$SB/secrets/cloudflare_token"

echo "delete: archive first, then DNS, containers, router, files"
mkdir -p "$SB/servers/s1/data/world" "$SB/servers/s1/backups"
echo level >"$SB/servers/s1/data/world/level.dat"; echo old >"$SB/servers/s1/backups/b1.tgz"
out=$( (confirm() { echo "ASKED: $1"; return 1; }; cmd_delete s1) 2>&1 ); rc=$?
assert_eq 4 "$rc" "a no: EX_REFUSED"
[[ $out =~ ASKED:.*$SB/trash/s1-[0-9]{8}T[0-9]{6}Z\.tar\.gz ]] && pass "the question names the archive path trash/s1-<UTC>.tar.gz" || fail "the question names the archive path" "$out"
assert_not_contains "$out" "cannot be brought back" "and no longer says it cannot be brought back"
assert_no_file "$SB/trash" "nothing was archived on a no"
mkdir -p "$SB/tarbin"; REALTAR=$(command -v tar); export REALTAR
cat >"$SB/tarbin/tar" <<'EOF'
#!/usr/bin/env bash
# stands in for tar while a test runs: -c fails, or with $FAKE_STATE/tar.garbage writes something that is not an archive
if [[ $1 == -czf ]]; then [[ -e $FAKE_STATE/tar.garbage ]] && { echo "not a tar file"; exit 0; }; echo "tar: injected failure" >&2; exit 2; fi
exec "$REALTAR" "$@"
EOF
chmod +x "$SB/tarbin/tar"
for how in fails garbage; do
    reset; rm -f "$FAKE_STATE/tar.garbage"; [[ $how == garbage ]] && : >"$FAKE_STATE/tar.garbage"
    PATH="$SB/tarbin:$PATH" run --yes delete s1
    assert_eq 4 "$RC" "tar $how: delete refuses (EX_REFUSED)"
    assert_eq "docker ps -a -q --filter label=mcctl.name=s1
$(dcl s1 stop)
$(archive_line "$SB/servers/s1")" "$(calls)" "tar $how: calls: the stop and the archive; no container removal, no DNS call"
    assert_file "$SB/servers/s1/data/world/level.dat" "tar $how: the world is untouched"
    assert_file "$SB/secrets/rcon-s1" "tar $how: and the secret"
    assert_eq "play.mc.example.net mcctl name=s1" "$(dns_records)" "tar $how: and the DNS record"
    assert_eq "" "$(ls -A "$SB/trash" 2>/dev/null)" "tar $how: no archive and no *.tmp is left in trash/ (E11)"
    assert_contains "$OUT" "nothing was deleted" "tar $how: the message says nothing was deleted"
done
rm -f "$FAKE_STATE/tar.garbage"
reset; echo 7 >"$FAKE_STATE/curl.DELETE.rc"
run --yes delete s1
assert_eq 1 "$RC" "the DNS delete fails: delete stops there, EX_FAIL"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
$(dcl s1 stop)
$(archive_line "$SB/servers/s1")
$(GET 'comment.exact=mcctl%20name%3Ds1')
$(DELETE rec1)" "$(calls)" "calls: stop, the archive, the DNS look-up and the failing DELETE, nothing after it: no container removal"
assert_contains "$OUT" "could not delete the DNS record play.mc.example.net" "a warning names the record"
assert_contains "$OUT" "nothing was removed" "the message says nothing was removed"
assert_contains "$OUT" "Run 'mcctl delete s1' again once Cloudflare answers" "and how to finish"
assert_file "$SB/servers/s1/data/world/level.dat" "the folder and the world are intact"
assert_file "$SB/secrets/rcon-s1" "and the secret"
assert_eq "play.mc.example.net mcctl name=s1" "$(dns_records)" "and the record, which still points at a server that exists"
arch=$(ls "$SB"/trash/s1-*.tar.gz 2>/dev/null)
[[ $arch =~ /trash/s1-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]] && pass "the archive is trash/s1-<UTC timestamp>.tar.gz" || fail "the archive is trash/s1-<UTC>.tar.gz" "$arch"
assert_eq "backups/
backups/b1.tgz
data/
data/world/
data/world/level.dat" "$("$REALTAR" -tzf "$arch" | tr -d '\r' | sort)" "it holds data/ and backups/"
assert_eq "level" "$("$REALTAR" -xzOf "$arch" data/world/level.dat)" "and the world reads back"
assert_contains "$OUT" "its archive is $arch" "the message names the archive"
assert_mode "$arch" 600 "the archive is mode 600"
assert_mode "$SB/trash" 700 "trash/ is mode 700"
reset
run --yes delete s1
assert_eq 0 "$RC" "run again once Cloudflare answers: delete completes"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
$(dcl s1 stop)
$(archive_line "$SB/servers/s1")
$(GET 'comment.exact=mcctl%20name%3Ds1')
$(DELETE rec1)
$(dcl s1 'rm -s -f')
$(sftp_ps_call)
$(clear_line "$SB/servers/s1")" "$(calls)" "calls: stop, the archive, the DNS record, then the containers, then SFTP, then the game's data"
assert_eq 0 "$(count_calls 'kill -s HUP')" "delete sends no router signal"
assert_eq "" "$(dns_records)" "the record is gone"
assert_no_file "$SB/servers/s1" "the folder is gone"
assert_no_file "$SB/secrets/rcon-s1" "and the secret"
fake_gone s1 play; reset
run --yes delete s1
assert_eq 1 "$RC" "once more: nothing is left, EX_FAIL"
assert_contains "$OUT" "no server named 's1'" "and it says so"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
$(GET 'comment.exact=mcctl%20name%3Ds1')" "$(calls)" "calls: the Docker check and one DNS look-up"
echo "-- nothing left of a server but its DNS record"
seed '[{"id":"o1","type":"A","name":"old5.mc.example.net","content":"203.0.113.7","comment":"mcctl name=s5"}]'
reset
run --yes delete s5
assert_eq 0 "$RC" "delete of a server with no container and no folder, but a record: the record is removed"
assert_eq "docker ps -a -q --filter label=mcctl.name=s5
$(GET 'comment.exact=mcctl%20name%3Ds5')
$(DELETE o1)" "$(calls)" "calls: Docker, the look-up by comment, the DELETE; no compose call, no router signal"
assert_eq "" "$(dns_records)" "the zone is empty"
echo "-- Cloudflare cannot be asked during delete"
reset
run create s4 --type PAPER --accept-eula; fake_server s4 s4
reset; echo 7 >"$FAKE_STATE/curl.GET.rc"
run --yes delete s4
assert_eq 1 "$RC" "the DNS look-up fails: EX_FAIL"
assert_eq 00 "$(count_calls 'rm -s -f')$(count_calls 'kill -s HUP')" "and delete stops there: no container removal, no router signal"
assert_file "$SB/servers/s4/compose.yaml" "the folder is intact"
assert_eq "s4.mc.example.net mcctl name=s4" "$(dns_records)" "and so is the record"
assert_contains "$OUT" "Run 'mcctl delete s4' again once Cloudflare answers" "the message says how to finish"
reset
run --yes delete s4
assert_eq 0 "$RC" "the second delete completes"
assert_eq "" "$(dns_records)" "the zone is empty"
assert_no_file "$SB/servers/s4" "and the folder is gone"
fake_gone s4 s4
echo "-- delete without the Cloudflare settings"
MCCTL_CF_ZONE_ID= run --yes delete s4
assert_eq 3 "$RC" "no MCCTL_CF_ZONE_ID: EX_PREFLIGHT"

echo "cf_relabel_record (Task 21: rename relabels the record in place; PATCH carries only the comment)"
PATCH() { echo "$CURL -X PATCH $H --data {\"comment\":\"mcctl name=$1\"} $API/$2"; }
reset
seed '[{"id":"rec9","type":"A","name":"play.mc.example.net","content":"203.0.113.7","proxied":false,"ttl":120,"comment":"mcctl name=old1"}]'
fn cf_relabel_record play old1 new1
assert_eq 0 "$RC" "relabel: 0 when the record has exactly 'mcctl name=old1'"
assert_eq "A play.mc.example.net 203.0.113.7 false 120 mcctl name=new1" "$(dns_records "$REC")" "the comment is now 'mcctl name=new1' and nothing else changed"
assert_eq "$(GET 'name=play.mc.example.net')
$(PATCH new1 rec9)" "$(calls)" "calls: one look-up of the name, one PATCH of the record's comment by id"
reset
seed '[{"id":"rec9","type":"A","name":"play.mc.example.net","content":"203.0.113.7","proxied":false,"ttl":120,"comment":"mcctl name=other"}]'
fn cf_relabel_record play old1 new1
assert_eq 1 "$RC" "a comment that is not 'mcctl name=old1' is refused"
assert_contains "$ERR" "has the comment 'mcctl name=old1': nothing was relabelled" "and the message says so"
assert_eq "A play.mc.example.net 203.0.113.7 false 120 mcctl name=other" "$(dns_records "$REC")" "the record is as it was"
assert_eq 0 "$(count_calls -X\ PATCH)" "no PATCH was sent"
reset
seed '[{"id":"rec9","type":"A","name":"play.mc.example.net","content":"203.0.113.7","proxied":false,"ttl":120,"comment":"mine"}]'
fn cf_relabel_record play old1 new1
assert_eq 1 "$RC" "a record one of the user's is never relabelled"
assert_eq "A play.mc.example.net 203.0.113.7 false 120 mine" "$(dns_records "$REC")" "and it is left as it was"
reset
seed '[]'
fn cf_relabel_record play old1 new1
assert_eq 1 "$RC" "no record of that name: 1"
assert_eq 0 "$(count_calls -X\ PATCH)" "and no PATCH"
reset
seed '[{"id":"rec9","type":"A","name":"play.mc.example.net","content":"203.0.113.7","proxied":false,"ttl":120,"comment":"mcctl name=old1"}]'
export FAIL_AT=1                                  # the PATCH is applied, its answer is lost (E7)
fn cf_relabel_record play old1 new1
unset FAIL_AT
assert_eq 1 "$RC" "a PATCH whose answer is lost: 1"
assert_eq "A play.mc.example.net 203.0.113.7 false 120 mcctl name=old1" "$(dns_records "$REC")" "it was set back to 'mcctl name=old1'"
assert_eq "$(GET 'name=play.mc.example.net')
$(PATCH new1 rec9)
$(PATCH old1 rec9)" "$(calls)" "calls: look-up, the PATCH (applied, answer lost), the PATCH back"
reset
seed '[{"id":"rec9","type":"A","name":"play.mc.example.net","content":"203.0.113.7","proxied":false,"ttl":120,"comment":"mcctl name=old1"}]'
echo 7 >"$FAKE_STATE/curl.PATCH.rc"
fn cf_relabel_record play old1 new1
assert_eq 1 "$RC" "Cloudflare cannot be reached for the PATCH: 1"
assert_eq "A play.mc.example.net 203.0.113.7 false 120 mcctl name=old1" "$(dns_records "$REC")" "and the record is as it was"
reset
fn cf_relabel_record "Bad Host" old1 new1
assert_eq 2 "$RC" "an invalid host name is EX_USAGE, before anything is asked"
assert_eq "" "$(calls)" "and Cloudflare is not asked"
assert_not_contains "$ALL" "$CF_TOKEN" "E4: the token is in no output of relabel"

echo "the token (E4)"
assert_not_contains "$ALL$(calls)" "$CF_TOKEN" "the token is in no output and not in the call log"
assert_contains "$(<"$REPO/.gitignore")" "/trash/" ".gitignore keeps trash/ out of git"

sandbox_cleanup
finish

#!/usr/bin/env bash
# shellcheck shell=bash
# Cloudflare DNS: one A record per server, HOST.MCCTL_DOMAIN -> MCCTL_PUBLIC_IPV4. Sourced by ./mcctl, never executed.
# With MCCTL_DNS=off (dns_on in lib/config.sh is false) none of these functions calls Cloudflare: local play needs no zone and no token.
#
# Every record mcctl makes is DNS-only (proxied: false; Cloudflare's proxy does not carry Minecraft, so the record shows this
# machine's public address) and carries the comment "mcctl name=<server>". mcctl deletes only records whose comment starts with
# "mcctl ", and never overwrites a record: a name that already has one is refused.
# The API token is the file secrets/cloudflare_token (mode 600). Only cf_api reads it, and it reaches curl on stdin as a curl
# config line (curl --config -), never as an argument: it is not in `ps`, in shell history or in the call log of the tests.
# curl -q comes first so that no ~/.curlrc is read: a `verbose` there would print the Authorization header.
# Needs curl and jq (mcctl doctor checks both). Every request is HTTPS only and gives up after 30 seconds. Lines of `jq -r` that are
# read in a loop go through `tr -d '\r'`: a jq built for Windows (Git Bash) ends its lines with CR LF.

CLOUDFLARE_API=https://api.cloudflare.com/client/v4
CLOUDFLARE_TOKEN_SECRET=cloudflare_token   # secrets/<this>
CF_FOUND=0                                 # set by cf_delete_server

# fqdn_for HOST -> stdout HOST.MCCTL_DOMAIN
fqdn_for() { printf '%s.%s\n' "${1-}" "$MCCTL_DOMAIN"; }

# _cf_token -> stdout the API token. EX_PREFLIGHT, naming the file and never printing what is in it, when the file is missing or
# does not hold one token alone on one line (a quote or a newline in it could add a line to curl's configuration).
_cf_token() {
    local f=$MCCTL_ROOT/secrets/$CLOUDFLARE_TOKEN_SECRET t
    [[ -f $f && -r $f ]] || { err "no Cloudflare API token: put it in $f, mode 600 (see 'Cloudflare DNS' in docs/reference.md)"; return "$EX_PREFLIGHT"; }
    t=$(<"$f")
    t=${t%$'\r'}
    [[ $t =~ ^[A-Za-z0-9._~+/=-]+$ ]] || { err "$f must hold the Cloudflare API token alone on one line"; return "$EX_PREFLIGHT"; }
    printf '%s\n' "$t"
}

# cf_ready: exit EX_PREFLIGHT, before anything is asked or changed, unless DNS records can be made: MCCTL_DOMAIN, MCCTL_PUBLIC_IPV4
# and MCCTL_CF_ZONE_ID are set, curl and jq exist, and secrets/cloudflare_token holds a token.
cf_ready() {
    local t
    dns_on || return 0
    require_config MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID
    for t in curl jq; do
        command -v "$t" >/dev/null 2>&1 || die "$t is needed to talk to Cloudflare: install the '$t' package" "$EX_PREFLIGHT"
    done
    _cf_token >/dev/null || exit "$EX_PREFLIGHT"
}

# cf_api METHOD PATH [JSON] -> stdout Cloudflare's answer. 0 only when it answered "success": true; otherwise 1 (EX_PREFLIGHT without
# a token) and a message with Cloudflare's own reason. PATH starts with /zones/. The JSON body is no secret, so it is an argument.
cf_api() {
    local method=${1-} path=${2-} tok out why
    local -a data=()
    tok=$(_cf_token) || return
    (($# < 3)) || data=(--data "$3")
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" |
        curl -q -sS --proto =https --max-time 30 --config - -X "$method" -H 'Content-Type: application/json' "${data[@]}" "$CLOUDFLARE_API$path") \
        || { err "Cloudflare could not be reached ($method $path): curl failed (see above)"; return 1; }
    jq -e '.success == true' >/dev/null 2>&1 <<<"$out" && { printf '%s\n' "$out"; return 0; }
    why=$(jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ")' 2>/dev/null <<<"$out" | tr -cd '[:print:]') || why="the answer is not Cloudflare's JSON"
    err "Cloudflare refused $method $path: ${why:-no reason given}"
    return 1
}

# cf_records QUERY -> stdout one JSON object per DNS record of the zone that matches QUERY (for example name=play.mc.example.net)
cf_records() {
    local out
    out=$(cf_api GET "/zones/$MCCTL_CF_ZONE_ID/dns_records?$1") || return
    jq -c '.result[]?' <<<"$out"
}

# _cf_describe < RECORDS -> stdout one line per record, for messages. A comment is anyone's text: it is quoted, control characters
# are removed.
_cf_describe() { jq -r '"\(.type) \(.name) -> \(.content), comment \(.comment // "none" | tojson)"' | tr -cd '[:print:]\n'; }

# cf_create_record HOST [NAME] -> stdout the id of a new record HOST.MCCTL_DOMAIN: type A, content MCCTL_PUBLIC_IPV4, ttl 120,
# proxied false, comment "mcctl name=NAME" (NAME defaults to HOST). EX_REFUSED, writing nothing, when the zone already has a record
# of that name: one mcctl did not make is never overwritten, and one it made belongs to a server that is gone or to an interrupted
# run. When the POST fails the answer may only have been lost on the way back, so any mcctl record of that name is deleted again.
cf_create_record() {
    local host=${1-} name=${2:-${1-}} fqdn recs body out id
    dns_on || return 0   # DNS off: no record, nothing printed
    valid_server_name "$host" || { err "invalid host name ${host@Q}"; return "$EX_USAGE"; }
    fqdn=$(fqdn_for "$host")
    recs=$(cf_records "name=$fqdn") || return 1
    if [[ -n $recs ]]; then
        err "Cloudflare already has a DNS record named $fqdn, and mcctl leaves it as it is: $(_cf_describe <<<"$recs" | paste -sd ';' -)"
        if jq -e 'select((.comment // "") | startswith("mcctl "))' >/dev/null 2>&1 <<<"$recs"; then
            err "mcctl made it for a server that is gone or in a create or delete that was cut short: 'mcctl delete <the name in its comment>' removes it"
        else
            err "remove it in the Cloudflare dashboard, or choose another host name with --hostname"
        fi
        return "$EX_REFUSED"
    fi
    body=$(jq -nc --arg n "$fqdn" --arg ip "$MCCTL_PUBLIC_IPV4" --arg c "mcctl name=$name" \
        '{type: "A", name: $n, content: $ip, ttl: 120, proxied: false, comment: $c}') || return 1
    if out=$(cf_api POST "/zones/$MCCTL_CF_ZONE_ID/dns_records" "$body") && id=$(jq -r '.result.id // empty' <<<"$out") \
        && [[ $id =~ ^[A-Za-z0-9]+$ ]]; then
        printf '%s\n' "$id"
        return 0
    fi
    err "the DNS record $fqdn was not made (see above)"
    cf_delete_record "$host" "$name" || warn "the DNS record $fqdn may exist all the same: 'mcctl delete $name' removes it"
    return 1
}

# _cf_delete_ids < "ID<TAB>NAME" LINES: DELETE each record; a warning names each one that could not be deleted. 1 when any failed.
_cf_delete_ids() {
    local id fq rc=0
    while IFS=$'\t' read -r id fq; do
        [[ -n $id ]] || continue
        cf_api DELETE "/zones/$MCCTL_CF_ZONE_ID/dns_records/$id" >/dev/null || { warn "could not delete the DNS record $fq (id $id)"; rc=1; }
    done
    return "$rc"
}

# jq: keep a record whose id is safe in a URL path and that mcctl made: with $c empty, any comment starting with "mcctl "; else the
# comment exactly $c. The check is made here, on what Cloudflare answered, whatever filter the request asked for.
CF_OWNED='(.id | type == "string" and test("\\A[A-Za-z0-9]+\\z"))
    and ((.comment // "") as $m | if $c == "" then ($m | startswith("mcctl ")) else $m == $c end)'

# cf_delete_record HOST [NAME]: delete the records named HOST.MCCTL_DOMAIN that mcctl made: those whose comment starts with "mcctl ",
# or, with NAME, only those whose comment is exactly "mcctl name=NAME". Any other record of that name is left as it is, and named.
# 0 when no such record is left (also when there was none); 1, naming each record that could not be deleted, otherwise.
cf_delete_record() {
    local host=${1-} c=${2:+mcctl name=$2} fqdn recs l
    dns_on || return 0
    valid_server_name "$host" || { err "invalid host name ${host@Q}"; return "$EX_USAGE"; }
    fqdn=$(fqdn_for "$host")
    recs=$(cf_records "name=$fqdn") || { warn "could not look up the DNS record $fqdn, so it was not deleted"; return 1; }
    [[ -n $recs ]] || return 0
    jq -c --arg c "$c" "select(($CF_OWNED) | not)" <<<"$recs" | _cf_describe | while IFS= read -r l; do info "left alone: $l"; done
    jq -r --arg c "$c" "select($CF_OWNED) | \"\\(.id)\\t$fqdn\"" <<<"$recs" | tr -d '\r' | _cf_delete_ids
}

# cf_delete_server NAME: delete every record mcctl made for the server NAME, whatever its host name: Cloudflare is asked for the
# comment "mcctl name=NAME", and of its answer only records whose comment is exactly that and whose name is one label under
# MCCTL_DOMAIN are deleted, by id. Sets CF_FOUND to the number of such records. 0 when none of them is left.
cf_delete_server() {
    local name=${1-} recs ids
    CF_FOUND=0
    dns_on || return 0
    valid_server_name "$name" || { err "invalid server name ${name@Q}"; return "$EX_USAGE"; }
    recs=$(cf_records "comment.exact=mcctl%20name%3D$name") || { warn "could not ask Cloudflare for the DNS records of $name"; return 1; }
    ids=$(jq -r --arg c "mcctl name=$name" --arg d ".$MCCTL_DOMAIN" \
        "select(($CF_OWNED) and (.name | type == \"string\" and endswith(\$d) and (rtrimstr(\$d) | test(\"\\\\A[a-z0-9-]+\\\\z\")))) | \"\\(.id)\\t\\(.name)\"" \
        <<<"$recs" | tr -d '\r')
    [[ -n $ids ]] || return 0
    CF_FOUND=$(grep -c . <<<"$ids")
    _cf_delete_ids <<<"$ids"
}

# _cf_patch_comment ID COMMENT: PATCH the comment of the record ID; nothing else of the record is sent
_cf_patch_comment() {
    local body
    body=$(jq -nc --arg c "$2" '{comment: $c}') || return 1
    cf_api PATCH "/zones/$MCCTL_CF_ZONE_ID/dns_records/$1" "$body" >/dev/null
}

# cf_relabel_record HOST OLD NEW: give the record HOST.MCCTL_DOMAIN the comment "mcctl name=NEW" in place of "mcctl name=OLD" (by id).
# Only a record whose comment is exactly "mcctl name=OLD" is changed; 1, changing nothing, when there is none, and the other records of
# that name are left alone. A PATCH whose answer was lost may still have changed the record, so it is set back to OLD (as
# cf_create_record does for a POST whose answer was lost).
cf_relabel_record() {
    local host=${1-} old=${2-} new=${3-} fqdn recs id
    dns_on || return 0
    valid_server_name "$host" || { err "invalid host name ${host@Q}"; return "$EX_USAGE"; }
    valid_server_name "$old" && valid_server_name "$new" || { err "invalid server name ${old@Q} or ${new@Q}"; return "$EX_USAGE"; }
    fqdn=$(fqdn_for "$host")
    recs=$(cf_records "name=$fqdn") || return 1
    id=$(jq -r --arg c "mcctl name=$old" "select($CF_OWNED) | .id" <<<"$recs" | tr -d '\r' | head -n 1)
    [[ -n $id ]] || { err "no DNS record of $fqdn has the comment 'mcctl name=$old': nothing was relabelled"; return 1; }
    _cf_patch_comment "$id" "mcctl name=$new" && return 0
    err "the DNS record $fqdn was not relabelled to 'mcctl name=$new' (see above)"
    _cf_patch_comment "$id" "mcctl name=$old" || warn "the DNS record $fqdn may say 'mcctl name=$new': set its comment back to 'mcctl name=$old' by hand"
    return 1
}

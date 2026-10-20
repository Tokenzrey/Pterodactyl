#!/usr/bin/env bash
# usage: mc-srv.sh <label> <target-host> <target-port>      e.g.  mc-srv.sh forge xyz.gl.at.ply.gg 41234
# needs in env (source from a chmod-600 file, never commit): CF_API_TOKEN CF_ZONE_ID CF_ZONE_NAME
set -euo pipefail
: "${CF_API_TOKEN:?}" "${CF_ZONE_ID:?}" "${CF_ZONE_NAME:?}"
label=$1 host=$2 port=$3
[[ $label =~ ^[a-z0-9]([a-z0-9-]{1,30}[a-z0-9])$ ]] || { echo "label must be 3-32 chars [a-z0-9-]" >&2; exit 1; }
[[ $port =~ ^[0-9]{2,5}$ ]] || { echo "bad port" >&2; exit 1; }
curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
  --data "$(jq -n --arg n "_minecraft._tcp.$label.$CF_ZONE_NAME" --arg h "$host" --argjson p "$port" \
        '{type:"SRV", name:$n, ttl:300, data:{priority:0, weight:5, port:$p, target:$h}}')" | jq '{success, errors}'

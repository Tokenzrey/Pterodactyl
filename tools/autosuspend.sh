#!/bin/sh
# Suspend servers that were OFFLINE on IDLE_DAYS consecutive daily checks.
# DRY_RUN=1 (default) only logs what it WOULD do — run it that way for a week first.
# ponytail: per-server counter files + one daily pass; move to an extension if you need per-user policies.
set -eu
API="${PANEL_URL:-http://panel}"; KEY="${PANEL_API_KEY:?set AUTOSUSPEND_API_KEY}"
IDLE_DAYS="${IDLE_DAYS:-14}"; DRY_RUN="${DRY_RUN:-1}"; STATE=/state
H="Authorization: Bearer $KEY"; A="Accept: application/json"
day=$(date +%F); mkdir -p "$STATE"
[ "$(cat "$STATE/last" 2>/dev/null || true)" = "$day" ] && exit 0      # once per day
page=1
while :; do
  r=$(curl -fsS -H "$H" -H "$A" "$API/api/application/servers?page=$page&per_page=100")
  echo "$r" | jq -r '.data[].attributes | select(.suspended==false) | "\(.id) \(.identifier)"' |
  while read -r id ident; do
    st=$(curl -fsS -H "$H" -H "$A" "$API/api/client/servers/$ident/resources" | jq -r '.attributes.current_state')
    f="$STATE/$id"
    if [ "$st" = offline ]; then
      n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
      echo "server $id offline ($n/$IDLE_DAYS)"
      if [ "$n" -ge "$IDLE_DAYS" ]; then
        if [ "$DRY_RUN" = 1 ]; then echo "DRY-RUN would suspend $id"
        else curl -fsS -X POST -H "$H" -H "$A" "$API/api/application/servers/$id/suspend" && echo "suspended $id" && rm -f "$f"; fi
      fi
    else echo 0 > "$f"; fi
  done
  [ "$(echo "$r" | jq '.meta.pagination.current_page < .meta.pagination.total_pages')" = true ] || break
  page=$((page+1))
done
echo "$day" > "$STATE/last"

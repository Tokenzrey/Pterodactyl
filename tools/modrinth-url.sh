#!/usr/bin/env bash
# usage: modrinth-url.sh <project-slug> <fabric|forge|neoforge|quilt> <mc-version>
# prints the newest *release* file URL, its sha512, and REQUIRED dependency project ids.
set -euo pipefail
slug=$1 loader=$2 mc=$3
curl -fsS -A "ptero-ops/1.0 (${ADMIN_EMAIL:-you@example.com})" -G "https://api.modrinth.com/v2/project/$slug/version" \
  --data-urlencode "loaders=[\"$loader\"]" --data-urlencode "game_versions=[\"$mc\"]" |
jq -e -r '[.[] | select(.version_type=="release")][0]
  | (.files | (map(select(.primary))[0] // .[0])) as $f
  | "\($f.url)\n# sha512 \($f.hashes.sha512)\n# requires: \([.dependencies[] | select(.dependency_type=="required") | .project_id] | join(" "))"'

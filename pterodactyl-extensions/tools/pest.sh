#!/usr/bin/env bash
# Menjalankan test Pest sebuah extension terhadap Panel di checkout.
# usage: tools/pest.sh <oauth-login|subdomain-manager> [argumen pest...]
# FAST=1 melewati migrate:fresh (pakai setelah run pertama).
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
with_test_lock
suite=${1:?usage: pest.sh <oauth-login|subdomain-manager> [argumen pest...]}
shift
"$TOOLS/db.sh" up >/dev/null || exit 1
[[ ${FAST:-0} == 1 ]] && export EXTRA_DOCKER_ARGS="${EXTRA_DOCKER_ARGS:-} -e SKIP_MIGRATIONS=1"
exec "$TOOLS/php.sh" -d memory_limit=2G vendor/bin/pest --configuration=/tools/phpunit.ext.xml --testsuite "$suite" "$@"

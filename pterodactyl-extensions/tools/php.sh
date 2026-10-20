#!/usr/bin/env bash
# Menjalankan PHP di image Panel yang dipatok (PHP 8.4, ada intl dan pdo_mysql) dengan checkout Panel di /app.
# Sumber extension terpasang read-only di /ext-src; skrip ini di /tools.
# Contoh: tools/php.sh artisan p:extension:list   |   tools/php.sh -v
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
need_docker
[[ -d $PANEL/vendor ]] || die "checkout Panel belum siap di $PANEL (jalankan tools/setup.sh)"

tty=(); [[ -t 0 && -t 1 ]] && tty=(-t)
# EXTRA_DOCKER_ARGS: argumen tambahan untuk `docker run` (mis. "-e SKIP_MIGRATIONS=1"), dipisah spasi
# shellcheck disable=SC2086
exec docker run --rm ${tty[@]+"${tty[@]}"} --user "$(id -u):$(id -g)" --network "$NET" --env-file "$TEST_ENV" \
    -e HOME=/tmp ${EXTRA_DOCKER_ARGS:-} \
    -v "$PANEL:/app" -v "$PROJECT/extensions:/ext-src:ro" -v "$TOOLS:/tools:ro" \
    -w /app --entrypoint php "$PANEL_IMAGE" "$@"

#!/usr/bin/env bash
# MariaDB sekali pakai untuk test Pest. up | down | status
# `down` hanya menghapus kontainer dan jaringan bernama ptero-ext-dev*; tidak menyentuh yang lain.
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
need_docker

case ${1:-} in
    up)
        umask 077
        mkdir -p "$ENV_ROOT"
        if [[ ! -f $TEST_ENV ]]; then
            pw=$(openssl rand -hex 16)
            key="base64:$(openssl rand -base64 32)"
            {
                echo "DB_HOST=$DB_CONTAINER"; echo "DB_PORT=3306"; echo "DB_DATABASE=testing"
                echo "DB_USERNAME=ptero_test"; echo "DB_PASSWORD=$pw"
                echo "APP_KEY=$key"; echo "APP_URL=https://panel.test"; echo "APP_ENV=testing"
                echo "CACHE_STORE=array"; echo "SESSION_DRIVER=array"; echo "QUEUE_CONNECTION=sync"; echo "MAIL_MAILER=array"
            } >"$TEST_ENV"
            { echo "MARIADB_DATABASE=testing"; echo "MARIADB_USER=ptero_test"; echo "MARIADB_PASSWORD=$pw"; echo "MARIADB_RANDOM_ROOT_PASSWORD=1"; } >"$DB_ENV"
        fi
        docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null || die "gagal membuat jaringan $NET"
        if docker container inspect "$DB_CONTAINER" >/dev/null 2>&1; then
            [[ $(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER") == true ]] || docker start "$DB_CONTAINER" >/dev/null
        else
            docker run -d --name "$DB_CONTAINER" --network "$NET" --env-file "$DB_ENV" --tmpfs /var/lib/mysql "$MARIADB_IMAGE" --max-connections=100 >/dev/null \
                || die "gagal menjalankan MariaDB"
        fi
        for _ in $(seq 1 60); do
            docker exec "$DB_CONTAINER" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && { echo "database siap"; exit 0; }
            sleep 2
        done
        die "MariaDB tidak siap dalam 120 detik"
        ;;
    down)
        docker rm -f "$DB_CONTAINER" >/dev/null 2>&1
        docker network rm "$NET" >/dev/null 2>&1
        echo "dihapus: $DB_CONTAINER, $NET (bila ada)"
        ;;
    status)
        docker ps -a --filter "name=^${DB_CONTAINER}$" --format '{{.Names}} {{.Status}}'
        ;;
    *) die "usage: db.sh {up|down|status}" ;;
esac

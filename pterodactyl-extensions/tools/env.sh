#!/usr/bin/env bash
# shellcheck shell=bash
# Dipakai (source) oleh skrip lain di folder ini. Hanya jalur dan image yang dipatok; tidak ada rahasia.
TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(dirname "$TOOLS")
# Lingkungan berat (checkout Panel, Node, basis data uji) tinggal di ext4 WSL, bukan di D: dan bukan di repositori deploy.
ENV_ROOT=${PTERO_EXT_ENV:-$HOME/pterodactyl-extensions-env}
PANEL=$ENV_ROOT/panel
export PATH="$ENV_ROOT/node/bin:$PATH"
# shellcheck source=versions.env
. "$TOOLS/versions.env"
NET=ptero-ext-dev
DB_CONTAINER=ptero-ext-dev-db
TEST_ENV=$ENV_ROOT/test.env     # DB_PASSWORD dan APP_KEY khusus uji, mode 600, di luar repositori
DB_ENV=$ENV_ROOT/db.env

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_docker() { docker info >/dev/null 2>&1 || die "daemon Docker tidak berjalan (nyalakan Docker Desktop)"; }
# Semua uji yang menyentuh basis data uji bersama (ptero-ext-dev-db, database testing) atau stack e2e harus lewat kunci ini:
# bootstrap menjalankan migrate:fresh, dan e2e menghapus ptero-ext-e2e-* di awal. Dua sesi bersamaan saling menghapus data.
with_test_lock() {
    mkdir -p "$ENV_ROOT/locks"
    exec 9>"$ENV_ROOT/locks/test.lock"
    flock -w 1800 9 || die "kunci uji dipegang lebih dari 30 menit (lihat docs/koordinasi-sesi.md)"
}

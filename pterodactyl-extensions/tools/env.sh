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

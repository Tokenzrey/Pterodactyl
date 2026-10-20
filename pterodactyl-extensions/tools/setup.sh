#!/usr/bin/env bash
# Menyiapkan lingkungan pengembangan. Aman diulang. Tidak mengubah apa pun di luar $ENV_ROOT dan kontainer ptero-ext-dev*.
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

[[ -d $PANEL/.git ]] || die "checkout Panel belum ada. Jalankan langkah pada README.md (git clone --branch $PANEL_TAG)"
actual=$(git -C "$PANEL" rev-parse HEAD)
[[ $actual == "$PANEL_COMMIT" ]] || die "checkout Panel di $actual, bukan $PANEL_COMMIT ($PANEL_TAG)"
[[ -x $ENV_ROOT/node/bin/node ]] || die "Node belum ada di $ENV_ROOT/node (lihat README.md)"
[[ -d $PANEL/vendor && -d $PANEL/node_modules ]] || die "dependensi Panel belum terpasang (composer install, npm ci)"

if [[ ! -d $PANEL/packages/sdk/testing-runtime ]]; then
    echo "membangun runtime test SDK..."
    (cd "$PANEL" && npm run sdk:testing) || die "npm run sdk:testing gagal"
fi
# Panel membaca /app/.env saat test; tanpa berkas ini PHPUnit melaporkan warning. Dikosongkan:
# nilai nyata datang dari env-file kontainer (mode 600), tidak dari berkas di checkout.
[[ -e $PANEL/.env ]] || : >"$PANEL/.env"
"$TOOLS/db.sh" up
echo "lingkungan siap: Panel $PANEL_TAG ($PANEL_COMMIT), Node $(node --version)"

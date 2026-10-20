#!/usr/bin/env bash
# Menyalin sumber sebuah extension ke checkout Panel (ext4) lalu menjalankan typecheck, test frontend, dan build.
# usage: tools/build.sh <id> [--skip-tests]
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
id=${1:?usage: build.sh <id> [--skip-tests]}
src=$PROJECT/extensions/$id
dst=$PANEL/extensions/$id
[[ -f $src/extension.json ]] || die "tidak ada $src/extension.json"

mkdir -p "$PANEL/extensions"
# node_modules dan dist tetap di tempat (di-exclude berarti juga tidak dihapus)
rsync -a --delete --exclude node_modules --exclude dist --exclude '*.pteroext' --exclude tests/ "$src/" "$dst/"
cd "$dst" || exit 1
[[ -f package.json ]] || { echo "tanpa frontend: tidak ada yang dibangun"; exit 0; }
# --legacy-peer-deps: npm 10 menabrak bug arborist ("reading 'edgesOut'") saat memuat peer set dari paket file:
# (@pterodactyl/sdk). Semua peer SDK sudah tercantum di devDependencies extension, jadi aman dilewati.
[[ -d node_modules ]] || npm install --no-audit --no-fund --loglevel=error --legacy-peer-deps || die "npm install gagal"
npm run typecheck || die "typecheck gagal"
[[ ${2:-} == --skip-tests ]] || npm test || die "test frontend gagal"
npm run build || die "build gagal"
# Setiap kelas ber-prefix yang ditulis di sumber harus ikut terbentuk di CSS hasil build (lihat check-classes.py).
css=$(ls dist/index.*.css 2>/dev/null | head -n1)
if [[ -n $css ]]; then python3 "$TOOLS/check-classes.py" "$src" "$css" || die "ada kelas ber-prefix yang tidak terbentuk di CSS"; fi
ls -la dist

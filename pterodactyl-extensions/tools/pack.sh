#!/usr/bin/env bash
# Compila, memeriksa (doctor) dan mengemas sebuah extension menjadi dist/<id>-<versi>.pteroext, lalu mencantumkan isinya.
# usage: tools/pack.sh <id>      (tidak memasang apa pun di Panel mana pun)
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
id=${1:?usage: pack.sh <id>}
src=$PROJECT/extensions/$id
[[ -f $src/extension.json ]] || die "tidak ada $src/extension.json"
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$src/extension.json" | head -n1)
[[ -n $version ]] || die "versi tidak terbaca dari extension.json"

"$TOOLS/build.sh" "$id" || exit 1
"$TOOLS/db.sh" up >/dev/null || exit 1

# Kemas dari salinan bersih: tanpa node_modules, test frontend, atau berkas CI (hanya yang dipakai saat runtime).
stage_rel="storage/ext-pack-stage/$id"
[[ -n $PANEL && -d $PANEL/storage ]] || die "checkout Panel tidak ditemukan"
rm -rf "${PANEL:?}/$stage_rel"
mkdir -p "$PANEL/$stage_rel" "$PANEL/storage/ext-pack" "$PROJECT/dist"
rsync -a --exclude node_modules --exclude '*.spec.ts' --exclude '*.spec.tsx' --exclude test-utils.tsx --exclude .github \
    "$PANEL/extensions/$id/" "$PANEL/$stage_rel/"

"$TOOLS/php.sh" artisan p:extension:doctor "$stage_rel" --no-ansi || die "doctor menolak $id"
out="storage/ext-pack/$id-$version.pteroext"
"$TOOLS/php.sh" artisan p:extension:pack "$stage_rel" --output="$out" --force --no-ansi || die "pack gagal"
cp "$PANEL/$out" "$PROJECT/dist/$id-$version.pteroext"

echo "== dist/$id-$version.pteroext"
python3 - "$PROJECT/dist/$id-$version.pteroext" <<'PY'
import hashlib, sys, zipfile
path = sys.argv[1]
with zipfile.ZipFile(path) as z:
    for info in z.infolist():
        print(f"{info.file_size:>9}  {info.filename}")
print("sha256", hashlib.sha256(open(path, "rb").read()).hexdigest())
PY

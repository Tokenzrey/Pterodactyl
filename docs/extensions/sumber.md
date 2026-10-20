# Sumber dan metode penelitian extension

> **Jenis:** Referensi · **Per:** 2026-10-20 · **Kembali ke:** [indeks extension](README.md)

Halaman ini mencatat dari mana setiap klaim di folder ini berasal, pada versi apa, dan bagaimana Anda bisa memeriksanya ulang. Dokumen upstream berubah, jadi tanggal dan commit di bawah adalah bagian yang paling penting.

## Sumber primer

| Sumber | URL | Versi / commit | Dipakai untuk |
|---|---|---|---|
| Halaman extension (web) | [docs.pterodactyl.io/v2/extensions](https://docs.pterodactyl.io/v2/extensions) dan sub-halamannya | dibaca 2026-10-20 | rujukan awal; dicocokkan dengan mdx |
| Sumber mdx dokumen | `pterodactyl/documentation`, branch `v2`, `content/docs/v2/extensions/*.mdx` | commit `d34763bd`, 2026-10-19T19:05:36Z | **teks yang dikutip** dan semua klaim dokumen |
| Panduan tema | `content/docs/v2/guides/customization/themes.mdx` (branch `v2`) | commit `d34763bd` | model tema upstream |
| Panduan Docker | `content/docs/v2/panel/docker.mdx` (branch `v2`) | commit `d34763bd` | volume extension |
| Panel (kode) | `pterodactyl/panel`, **tag** `v2.0.0-beta.2` | commit `ea742d33`, 2026-10-14T08:01:26Z | semua klaim "(kode)" dan kompatibilitas |
| Paket resmi | `pterodactyl/extensions` v1.0.1, `announcements.zip` dan `custom-buttons.zip` | sha256 cocok `extensions.lock` | verifikasi hash dan manifest |
| Paket lokal | `extensions/unix/unix.pteroext` | sha256 cocok `extensions.lock` | verifikasi hash dan manifest |

## Cara penelitian

1. **Pencarian awal.** Halaman web dibaca untuk menemukan struktur, lalu sub-halamannya ditelusuri lewat tautan relatif. Hasilnya disimpan sebagai rujukan, tidak sebagai sumber.
2. **Teks sumber, bukan ringkasan.** Setiap halaman diambil dari repositori dokumentasi (berkas mdx di branch `v2`) dalam bentuk mentah. Ringkasan dari alat web tidak dipakai untuk mengutip, karena alat itu meringkas dan kadang mengubah angka, nama, atau kode.
3. **Kode sebagai pembanding.** Setiap klaim yang bisa diuji terhadap kode dibandingkan dengan tag `v2.0.0-beta.2`. Hasilnya dicatat di [kompatibilitas](kompatibilitas.md). Klaim yang tidak sempat dibandingkan ditandai "belum diverifikasi".
4. **Hash paket dihitung ulang.** Paket di `extensions.lock` diunduh, sha256-nya dibandingkan dengan lock, dan manifest dibaca dari isi zip. Tidak ada paket yang diekstrak atau dijalankan.
5. **Versi dicocokkan.** Tanggal commit tag, branch, dan dokumen dicatat, karena Panel dan dokumennya berubah.

## Pemeriksaan kode yang dilakukan

| Pemeriksaan | Berkas kode (tag beta.2) | Hasil |
|---|---|---|
| Validator manifest | `app/Services/Extensions/ExtensionManifestValidator.php` | aturan kunci, regex, `ui.views`, `theme` |
| Konstanta manifest | `app/Services/Extensions/ExtensionManifest.php` | regex ID, ikon, tipe, daftar dicadangkan |
| Kompatibilitas dan urutan | `app/Services/Extensions/ExtensionCompatibility.php` | versi runtime, dependensi, autoloader, nama migrasi |
| Konfigurasi | `config/extensions.php` | sdk_version, retensi, batas, URL bertanda tangan |
| Tipe setting | `app/Services/Extensions/ExtensionSettingDefinition.php` | sepuluh tipe field, aturan rahasia dan file |
| Tema | `app/Services/Themes/ThemeRepository.php`, `ThemeSetting.php`, `ThemeDefinition.php` | tipe setting, stylesheet, skema, nama setting |
| Command | `app/Console/Commands/Extensions/*.php`, `app/Console/Commands/Themes/*.php` | signature dan opsi |
| Batas unggah | `app/Http/Requests/Api/Admin/Extensions/InstallExtensionRequest.php` | `max:51200` KB |
| SDK | `packages/sdk/types/**`, `packages/sdk/package.json`, `manifest.schema.json` | ada atau tidaknya API |
| Contoh | `packages/hello-world/extension.json`, `packages/sdk/docs-samples/` | `ui.views`, `requires.sdk` |
| Paket | `extensions/extensions.lock` dan unduhan rilis | sha256 dan manifest |

## Yang tidak dipakai sebagai bukti

- Ringkasan halaman dari alat web. Dipakai hanya untuk menemukan struktur.
- Hasil pencarian umum. Hasil pencarian untuk `p:extension:install` dan `extension.json` menemukan Blueprint dan proyek lain, bukan Panel 2.0. Hasil itu diabaikan.
- Panduan stack lama, [Pterodactyl-Docker-WSL2-Deployment-Guide.md](../Pterodactyl-Docker-WSL2-Deployment-Guide.md), termasuk bagian 7.3 tentang membangun tema `unix`. Itu catatan dari Panel yang lebih lama dan bukan sumber untuk kompatibilitas beta.2.

## Cara memverifikasi ulang

Langkah ini diperlukan setiap kali Panel dinaikkan versinya, atau setiap kali dokumen upstream berubah.

1. **Cek commit tag dan branch.** Ambil SHA tag, lalu bandingkan dengan branch rilis dan `main`/`develop`:

   ```text
   https://api.github.com/repos/pterodactyl/panel/git/ref/tags/<versi>
   https://api.github.com/repos/pterodactyl/panel/compare/<versi>...release/<versi>
   ```

2. **Unduh teks sumber mentah** dari `raw.githubusercontent.com` dengan SHA tag atau nama branch, mis.:

   ```text
   https://raw.githubusercontent.com/pterodactyl/documentation/v2/content/docs/v2/extensions/reference.mdx
   https://raw.githubusercontent.com/pterodactyl/panel/<tag>/app/Services/Extensions/ExtensionManifestValidator.php
   ```

3. **Cari fitur yang dipermasalahkan** di validator, SDK, dan daftar command. Untuk setiap selisih, perbarui tabel di [kompatibilitas](kompatibilitas.md).

4. **Hitung ulang hash paket** di `extensions.lock` setelah paket diganti. Hash yang tidak cocok berarti paket atau lock harus diperiksa sebelum `./ptero ext install`.

5. **Jalankan suite** (`bash tests/run.sh`) dan `python3 -I tests/check_docs.py`. Perubahan di halaman ini harus lolos pemeriksaan tautan.

Menjalankan ulang langkah ini tanpa token GitHub dibatasi laju permintaannya (60 permintaan per jam per alamat IP). Untuk pemeriksaan besar, gunakan autentikasi GitHub dengan token Anda sendiri, dan jangan menyimpan token itu di repositori.

## Batas penelitian

- Saya tidak menjalankan Panel beta.2 nyata untuk memeriksa perilaku extension yang didokumentasikan. Klaim perilaku ditandai "(kode)" atau "dokumen", bukan "terverifikasi".
- Ikon, polling SDK, dan isi daftar slot belum dicocokkan penuh (lihat [kompatibilitas](kompatibilitas.md#yang-belum-diverifikasi)).
- Pemeriksaan pada Panel nyata di repositori ini sebelumnya memasang `announcements`, `custom-buttons`, dan `unix` dengan hasil berhasil. Itu dicatat di [verifikasi](../verification.md) dan tidak diulang di sini.

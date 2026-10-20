# Mengelola extension: pasang, aktifkan, perbarui, hapus

> **Jenis:** Panduan · **Per:** 2026-10-20 · **Sumber utama:** [docs.pterodactyl.io/v2/extensions](https://docs.pterodactyl.io/v2/extensions), halaman "Extensions" · **Diperiksa di kode:** tag `v2.0.0-beta.2` pada `app/Console/Commands/Extensions/*.php` · **Kembali ke:** [indeks extension](README.md)

Extension tidak aktif sampai Anda mengaktifkannya. Pemasangan, aktivasi, nonaktivasi, dan penghapusan bisa dilakukan dari **Admin → Extensions** atau dari Artisan. Halaman ini menjelaskan setiap tahap, apa yang terjadi di Panel, dan apa yang tetap tersimpan.

## Format paket

Extension dikirim sebagai berkas `.pteroext`, yaitu arsip zip dari direktori extension. Perintah `p:extension:install` juga menerima `.zip` dan direktori yang belum dikemas.

| Cara | Batas atau catatan |
|---|---|
| Unggah di Admin | `.pteroext` atau `.zip`, maksimum **50 MB** (di kode: `max:51200` KB) |
| `p:extension:install` dengan direktori | menyalin semuanya, termasuk file pengembangan seperti `node_modules` |

Pakai `.pteroext` untuk distribusi. Direktori hanya untuk pengembangan lokal.

## Pasang

**Dari Admin:** buka **Admin → Extensions**, klik **Install**, pilih berkas, lalu centang **Enable after install** bila ingin langsung aktif.

**Dari baris perintah:**

```bash
php artisan p:extension:install /path/ke/server-notes.pteroext --enable
```

Opsi yang ada di kode (tag `v2.0.0-beta.2`, `InstallCommand.php`):

| Opsi | Arti |
|---|---|
| `--enable` | aktifkan setelah pemasangan, termasuk menjalankan migrasinya |
| `--replace` | ganti extension dengan ID yang sama tanpa bertanya |

Argumen `path` juga menerima **URL install bertanda tangan** (*signed install URL*). Dokumen upstream belum membahas jalur ini. Lihat [uji dan paket](uji-dan-paket.md#keamanan) untuk risikonya.

Setelah pemasangan, beri kepemilikan direktori ke user web server. Dokumen upstream memberi contoh untuk server biasa:

```bash
chown -R www-data:www-data /var/www/pterodactyl/extensions /var/www/pterodactyl/public/assets/extensions
```

Di image Docker, user web server adalah `nginx`. Repositori ini menyerahkan kepemilikan itu ke `nginx` secara otomatis saat `./ptero ext install` (lihat [bagian repositori ini](#di-repositori-ini)).

## Aktifkan dan nonaktifkan

```bash
php artisan p:extension:enable server-notes
php artisan p:extension:disable server-notes
```

**Saat aktivasi**, Panel memeriksa, berurutan:

1. versi yang disyaratkan: `requires.panel`, `requires.sdk`, `requires.php`;
2. extension yang disyaratkan di `requires.extensions` harus sudah aktif dan cocok versinya;
3. berkas frontend hasil build sudah ada.

Setelah itu Panel menjalankan migrasi di `database/migrations`, mempublikasikan aset, dan baru menandai extension aktif. Bila salah satu langkah gagal, extension tetap di state dan versi aset sebelumnya.

**Saat nonaktifkan**, halaman, endpoint API, dan kode frontend berhenti. File, data, dan pengaturan tetap ada. Nonaktifkan extension yang bergantung padanya lebih dulu; kode menolak sebaliknya (`Disable dependent extension ... before ...`).

Pemasangan, aktivasi, nonaktivasi, atau penghapusan membuat cache rute disegarkan dan meminta worker queue dimulai ulang. Pengguna harus memuat ulang halaman untuk mendapat kode frontend terbaru.

## Konfigurasi

Buka **Admin → Extensions** lalu klik tombol pengaturan pada kartu extension. Tombol itu hanya muncul untuk extension yang aktif.

- Pengaturan disimpan di basis data Panel.
- Nilai rahasia terenkripsi dan tampil kosong di form. Kosongkan kolomnya untuk mempertahankan nilai tersimpan.
- Perubahan pengaturan frontend baru terlihat setelah halaman dimuat ulang.

## Perbarui

Pasang paket versi baru dengan cara yang sama seperti pemasangan pertama.

- State aktif atau nonaktif dipertahankan.
- Bila aktivasi gagal, Panel mengembalikan paket, versi, state, dan versi aset sebelumnya.
- **Perubahan skema migrasi tidak bisa dibatalkan** oleh mekanisme ini. Simpan backup basis data sebelum memperbarui, dan periksa migrasi yang mungkin sudah berjalan sebagian sebelum mencoba lagi.
- Aset dipublikasikan di direktori berversi. Sesi browser yang sudah terbuka tetap bisa memuat berkas lama sampai halaman dimuat ulang.

## Hapus

Dari Admin, atau:

```bash
php artisan p:extension:remove server-notes
```

- Berkas extension dan aset yang dipublikasikan dihapus.
- **Tabel basis data dan pengaturannya tetap ada.** Pemasangan ulang akan memulihkan datanya.
- Untuk menghapus data, hapus tabelnya secara manual. Konvensi namanya: awalan `ext_` diikuti ID extension, dengan tanda hubung diganti garis bawah (mis. `ext_server_notes_notes`).

## Daftar extension

```bash
php artisan p:extension:list
```

Kolom yang ditampilkan: `ID`, `Name`, `Version`, `UI` (ada frontend atau tidak), `State`, dan `Error`. Contoh dari dokumen upstream:

```text
+--------------+--------------+---------+-----+---------+-------+
| ID           | Name         | Version | UI  | State   | Error |
+--------------+--------------+---------+-----+---------+-------+
| server-notes | Server Notes | 1.0.0   | yes | enabled |       |
+--------------+--------------+---------+-----+---------+-------+
```

## Variabel lingkungan

| Variabel | Bawaan | Arti |
|---|---|---|
| `PTERODACTYL_EXTENSIONS_ENABLED` | `true` | `false` mematikan semua extension tanpa menghapusnya |
| `PTERODACTYL_EXTENSIONS_DIRECTORY` | `extensions` di direktori Panel | lokasi pemasangan |
| `PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED` | `true` | mengaktifkan pemasangan dari URL bertanda tangan (`config/extensions.php`, `signed_urls.enabled`) |

Dari `config/extensions.php` (tag `v2.0.0-beta.2`): `progress_retention_seconds` 3600, `root_routes_per_minute` 120, `files_disk` `local` (harus disk privat, disk `public` ditolak).

User web server harus bisa menulis ke direktori extension dan ke `public/assets/extensions`. Tanpa itu, pemasangan dan penghapusan dari Admin gagal.

Di Docker, simpan `/app/extensions` dan `/app/public/assets/extensions` di volume. Tanpa itu, extension hilang saat container dibuat ulang. Contoh Compose di dokumen upstream sudah melakukannya.

## Bila gagal

| Gejala | Penyebab | Yang dilakukan Panel |
|---|---|---|
| Extension tampil dengan error saat Panel start | provider melempar exception | Panel melewati extension, error tampil di kartu Admin dan di kolom `Error`. Panel mencoba lagi setiap request, jadi error hilang setelah masalah diperbaiki |
| Status **invalid** | `extension.json` rusak | extension tidak bisa diaktifkan sampai file diperbaiki |
| Halaman atau konten extension tidak muncul | konten gagal dimuat | pengguna melihat tombol coba lagi (galat render) atau muat ulang (berkas layar gagal). Admin → Extensions juga menampilkan galat frontend dari browser yang sedang dipakai |
| Field tambahan di form admin hilang | nilai tersimpan tidak bisa dibaca | field disembunyikan di halaman edit agar penyimpanan tidak menimpa data. Penyebabnya dicatat di kartu extension |

## Di repositori ini

Repositori ini membungkus alur di atas dengan `./ptero`:

| Yang Anda lakukan | Yang terjadi |
|---|---|
| Mengisi `PANEL_EXTENSIONS` dan `PANEL_THEME` di `config/deploy.env` | `./ptero setup` dan `./ptero ext install` memasang daftar itu |
| Menambahkan id ke `PANEL_EXTENSIONS` | hanya id yang ada di `extensions/extensions.lock` yang diterima; paket dicocokkan dengan sha256 yang dikunci |
| `./ptero ext install` | backup `pre-extensions` dibuat dulu bila Panel sudah berisi data; paket dialirkan ke container dan dipasang dengan `p:extension:install --enable` |
| Mengatur `PANEL_EXTENSIONS_ENABLED=false` lalu `./ptero up` | saklar darurat, diteruskan ke `PTERODACTYL_EXTENSIONS_ENABLED` |

Volume di `compose.yml`: `panel_extensions` dipasang ke `/app/extensions` dan `panel_extension_assets` ke `/app/public/assets/extensions`. Keduanya sesuai dengan catatan Docker di dokumen upstream. Detail alur repositori: [docs/extensions.md](../extensions.md).

## Lihat juga

- [Membangun extension](membangun.md), untuk paket baru.
- [Uji dan paket](uji-dan-paket.md), untuk memeriksa paket sebelum dipasang.
- [Kompatibilitas](kompatibilitas.md), untuk versi Panel dan SDK yang sebenarnya dikirim.

# Ekstensi Panel, tema, dan baseline Panel (otomatis)

> **Jenis:** Panduan + referensi · **Untuk:** operator yang mengatur tampilan dan fitur Panel · **Status verifikasi:** pemasangan dan tema **nyata** pada Panel 2.0 beta.2 (unduhan asli, sha256 dicocokkan); menambah ekstensi di luar tiga yang terkunci **belum diuji**

Semua yang dulu dipasang manual di stack WSL (`announcements`, `custom-buttons`, tema `unix`, dan pengaturan dasar Panel) sekarang dipasang oleh `./ptero setup` dari konfigurasi, tanpa langkah tambahan. Setiap ekstensi berjalan dengan **akses penuh ke Panel** (basis data, pengaturan, pengguna), jadi hanya paket yang tercantum di `extensions/extensions.lock`, dengan sha256 dan versi yang cocok, yang bisa dipasang.

Untuk cara membangun extension sendiri (backend, frontend, uji, paket) dan referensi lengkap dari dokumentasi upstream, lihat [Extension Pterodactyl](extensions/README.md). Halaman itu juga mencatat selisih antara dokumen upstream dan Panel beta.2 yang dikunci repositori ini.

## Yang dipasang secara bawaan

| Item | Isi | Sumber |
|---|---|---|
| `announcements` v1.0.0 | spanduk pengumuman di seluruh Panel (misalnya "restart jam 03:00") | rilis resmi `pterodactyl/extensions` **v1.0.1**, sha256 dipatok |
| `custom-buttons` v1.0.0 | tombol tautan di halaman server (Discord, aturan, modpack) | sama |
| `unix` v1.0.0 (**tema**) | tampilan terminal, **mode malam (phosphor) dan siang (paper)**: tema mendeklarasikan kedua skema dan Panel menyediakan pemilih Dark, Light, atau System untuk tema seperti itu (letak persis menunya belum diperiksa secara visual); stylesheet 18 KB, tanpa webfont; opsi radius sudut, spasi ringkas, logo | sumber dan paket jadi di `extensions/unix/` (sha256 dipatok), dibawa dari stack lama |
| Egg modpack | "Minecraft Modpack (CurseForge / Modrinth)" | `eggs/modpack-installer/`; hanya bila `GAMES_ENABLED=yes` ([Server Minecraft](games.md)) |
| Baseline Panel (env) | telemetri mati; retensi log aktivitas staf 365 hari (`ACTIVITY_PRUNE_DAYS`) dan tetap terlihat oleh pemilik server; backup server tetap di node; saklar darurat ekstensi (`PANEL_EXTENSIONS_ENABLED`) | `compose.yml` |
| Tuning Wings | batas PID, cek disk, batas tulis backup, `stop` bersih tidak dianggap crash, batas unggah 100 MB, throttle konsol (`WINGS_TUNING=yes`) | `lib/wings_config.py`; hanya kunci yang sudah ada. Daftar lengkap: [Operasi](operations.md#wings-dari-node-di-panel-sampai-hijau) |

Pilihan ada di `config/deploy.env`:

```ini
PANEL_EXTENSIONS=announcements,custom-buttons,unix   # kosongkan untuk tidak memasang apa pun
PANEL_THEME=unix                                     # atau classic
PANEL_EXTENSIONS_ENABLED=true                        # false + ./ptero up = matikan semua ekstensi bila Panel rusak
ACTIVITY_PRUNE_DAYS=365
```

Aturan validasi tiap variabel ada di [Referensi konfigurasi](configuration.md#ekstensi-dan-tema-panel).

## Cara kerja dan jaminan

- `./ptero setup` memasang sisanya **setelah Panel sehat**. Untuk tiap id di `PANEL_EXTENSIONS` ia mengunduh paket dari rilis yang dipatok (atau memakai berkas lokal), **mencocokkan sha256 dan versi** dengan `extensions/extensions.lock`, mengalirkannya ke container Panel, menjalankan `p:extension:install --enable`, memberi kepemilikan direktori ke `nginx` (syarat upstream), lalu mengaktifkan tema (`p:theme:activate`).
- **Idempoten.** Yang sudah terpasang, aktif, dan berversi sama dilewati. Hasil jalan kedua: "already installed and enabled".
- **Backup lebih dulu** (`pre-extensions`) bila ada yang akan dipasang di Panel yang sudah berisi, karena migrasi ekstensi tidak bisa dibalik. Backup gagal berarti tidak ada ekstensi yang disentuh. Pada instalasi baru (basis data baru saja dimigrasi) backup dilewati.
- Kegagalan memasang ekstensi **tidak menggagalkan `setup`**: Panel tetap hidup, dan pesannya menyebut `./ptero ext install` untuk mengulang.
- **Tidak pernah menghapus.** Ekstensi yang dikeluarkan dari daftar tidak dihapus (tabel `ext_*`-nya tetap ada walau dihapus). Tema bisa dikembalikan dengan `PANEL_THEME=classic` (`p:theme:reset`). Menghapus adalah keputusan manusia: `./ptero compose exec panel php artisan p:extension:remove <id>`.
- Ekstensi dan tema ada di volume `panel_extensions` dan `panel_extension_assets`, sehingga ikut `./ptero backup` dan `restore`; tema aktif (pengaturan di basis data) bertahan dari pembuatan ulang container.

Perintah sehari-hari: `./ptero ext list` (tabel ID, versi terkunci, terpasang, diminta; plus tema yang diminta dan aktif), `./ptero ext install [--no-backup]`, dan `./ptero ext vet FILE`. Panel rusak setelah ekstensi? Set `PANEL_EXTENSIONS_ENABLED=false` di `deploy.env`, jalankan `./ptero up`, perbaiki, lalu kembalikan ke `true`.

**Hasil uji (nyata, satu `./ptero setup` pada Panel baru):** ketiga paket terpasang dan `enabled` menurut `p:extension:list` Panel sendiri; tema `unix` `active` menurut `p:theme:list`; halaman login menyajikan `data-theme="unix"` dan `/assets/extensions/unix/<hash>/theme.css`; direktori ekstensi dimiliki `nginx`; menjalankan `ext install` kedua tidak mengubah apa pun dan tidak membuat backup tambahan. Rincian: [Verifikasi](verification.md).

## Menambah ekstensi lain

Setiap ekstensi berjalan dengan akses penuh ke Panel. Prosedurnya:

1. Unduh paket ke direktori kosong dan periksa dengan `vet` **sebelum** mempercayainya:

   ```bash
   curl -fsSLO https://github.com/pterodactyl/extensions/releases/download/v1.0.1/redirect.zip
   ./ptero ext vet redirect.zip
   ```

   `vet` mencetak id, versi, sha256, dan jejak panggilan berbahaya di PHP-nya, tanpa memasang apa pun.
2. **Baca kode paket itu sendiri.** `vet` adalah penyaring awal, bukan bukti keamanan: ia menandai eksekusi perintah (`exec`, `shell_exec`, `system`, `passthru`, `proc_open`, `eval`), HTTP keluar dari PHP, `unserialize`, dan `base64_decode`.
3. Tambahkan satu baris ke `extensions/extensions.lock` dengan format `id  sha256  versi  sumber`.
4. Masukkan id ke `PANEL_EXTENSIONS` di `deploy.env`.
5. Jalankan `./ptero ext install`.

Dua paket resmi lain di rilis yang sama (`redirect`, `dark-theme`) sudah ada di lock sebagai komentar; keduanya **belum ditinjau** di sini. `dark-theme` tidak diperlukan karena tema `unix` sudah punya mode gelap.

Paket Blueprint atau BuiltByBit untuk Panel 1.x tidak kompatibel dengan Panel 2.0 dan tidak didukung (upstream menyatakan modifikasi addon 1.x tidak terbawa).

## Tema `unix`: mengubah atau membangun ulang

Sumber ada di `extensions/unix/src/theme.css` dan `extension.json`; paket jadi di `extensions/unix/unix.pteroext` (sha256 di lock). Mengubah warna berarti membangun ulang paket (SDK Panel dan Node di container sekali pakai), lalu memperbarui sha256 dan versi di lock. Langkah persisnya, yang dijalankan pada stack lama, ada di [panduan WSL2 lama](Pterodactyl-Docker-WSL2-Deployment-Guide.md) bagian 7.3 (arsip; tidak dipelihara). Tanpa membangun ulang, tiga pengaturan dapat diubah dari **Admin → Extensions**: radius, spasi ringkas, dan logo.

## Yang bukan bagian dari otomasi ini

Dari catatan stack lama, hal berikut tidak dibawa karena bukan ekstensi atau bergantung pada layanan eksternal Anda:

- Aturan Cloudflare (cache, WAF, Bot Fight, Access): dashboard, lihat [Cloudflare](cloudflare.md).
- reCAPTCHA dengan kunci milik Anda dan kewajiban 2FA: *Admin → Settings*, tersimpan di basis data.
- SMTP: *Admin → Settings → Mail*.
- Pekerjaan `autosuspend` untuk server idle, terkait server game lama; belum diporting.

# Pengembangan dan pemeliharaan

> **Jenis:** Panduan · **Untuk:** pemelihara dan kontributor kode · **Prasyarat:** bash 4.4+, python3 3.8+; Docker nyata hanya diperlukan untuk dua pemeriksaan opsional

Halaman ini menjelaskan struktur kode, prinsip yang dipegang setiap perubahan, cara menjalankan test, dan prosedur pemeliharaan yang berulang: menaikkan versi, membangun ulang egg, dan menjaga dokumentasi. Bacalah [Arsitektur](architecture.md) dan [Keamanan](security.md) lebih dulu; perubahan yang melanggar prinsip di sana akan ditolak oleh test atau tinjauan.

## Struktur kode

| Berkas | Peran |
|---|---|
| `ptero` | titik masuk: memuat `lib/*.sh`, mengurai `--yes`, mengarahkan perintah |
| `lib/common.sh` | helper: `info`, `warn`, `die`, `confirm`, `wait_until`, `read_hidden`, `write_secret`, `redact`; kode keluar; direktori sementara privat |
| `lib/config.sh` | pemuatan (`load_envfile`), validasi (`validate_config`), pemeriksaan rahasia, nilai bawaan |
| `lib/preflight.sh` | pemeriksaan host yang hanya membaca |
| `lib/stack.sh` | `init`, `setup`, `up`, `down`, `status`, `logs`, `admin`, `tunnel`, `verify`, `update` |
| `lib/backup.sh` | `backup`, `restore`, `restore-config` |
| `lib/wings.sh`, `lib/wings_config.py` | pemasangan Wings dan penambalan config (parser YAML minimal yang hanya mengubah baris yang dimaksud) |
| `lib/firewall.sh` | ufw, dead-man switch, egress guard, `audit` |
| `lib/ext.sh`, `lib/ext_vet.py` | ekstensi dan tema, pemeriksaan paket |
| `lib/games.sh`, `lib/games.py` | router game, `game create`, `games sync`; `games.py` berbicara dengan API Panel |
| `lib/egg.sh`, `lib/egg_build.py` | egg modpack dan penyimpanan kunci |
| `lib/diag.sh`, `lib/redact.py` | `diagnose` dan penyamaran rahasia |
| `eggs/modpack-installer/` | `installer.py` (dijalankan di container install Wings), `egg.template.json`, `modpack-installer.egg.json` (dihasilkan) |
| `extensions/` | `extensions.lock`, tema `unix` (sumber dan paket jadi) |
| `systemd/*.tpl` | templat unit: Wings, egress guard, sinkronisasi nama host |
| `tests/` | `run.sh`, helper `lib.sh`, `t_*.sh`, `test_*.py`, tiruan di `fakebin/`, fixture |

## Prinsip yang dipegang setiap perubahan

1. **Tidak ada `set -e`.** Setiap langkah yang bisa gagal dicek dan berakhir pada `die` atau `return 1` dengan pesan yang menyebut apa yang harus dilakukan berikutnya dan keadaan data.
2. **Tidak ada perintah yang menghapus data.** Volume, backup, `secrets/`, dan data Wings tidak pernah dihapus oleh skrip. `t_static.sh` memindai kode untuk memastikannya.
3. **Konfigurasi di-parse, bukan di-source.** `config/*.env` dibaca baris demi baris dengan whitelist karakter.
4. **Rahasia tidak pernah menjadi argumen, tidak di log, tidak di repositori.** Dibaca dari `secrets/` atau prompt tersembunyi; berkas ditulis atomik dengan mode 600 (`write_secret`). `t_static.sh` memindai repositori untuk pola rahasia.
5. **Aman diulang.** Menjalankan ulang `setup`, `wings install`, dan `firewall apply` tidak mengubah yang sudah benar.
6. **Konfirmasi untuk tindakan berisiko.** Lewat `confirm`; `--yes` untuk otomasi; frasa (`RESTORE`) untuk tindakan yang menimpa data.
7. **Kode keluar bermakna.** 0, 1, 2, 3, 4 seperti di [Referensi konfigurasi](configuration.md#kode-keluar).
8. **Tidak memodifikasi sumber upstream.** Panel dan Wings dipakai apa adanya; penyesuaian lewat konfigurasi dan environment.
9. **Egg dan ekstensi dipasang lewat jalur resmi Panel** (aksi impor, perintah `p:extension:*`), bukan SQL langsung. Satu-satunya impor SQL adalah `restore` dari dump milik Panel sendiri.

## Menjalankan test

```bash
bash tests/run.sh                 # semua t_*.sh
bash tests/run.sh t_wings.sh      # satu berkas
python3 -I tests/check_docs.py    # hanya pemeriksaan dokumentasi
```

Test tidak memerlukan Docker nyata, jaringan, atau domain. `docker`, `curl`, `systemctl`, `systemd-run`, `ufw`, `iptables`, `sshd`, `getent`, `nc`, dan `ss` (lewat `fakess` dan `PTERO_SS`) ditiru di `tests/fakebin/`, dan setiap test bekerja pada salinan repositori di direktori sementara (`sandbox` di `tests/lib.sh`). Dua pemeriksaan opsional di `t_static.sh` hanya berjalan bila `docker` nyata tersedia: render `docker compose config` dan shellcheck.

| File | Cakupan |
|---|---|
| `t_config.sh`, `t_stack.sh`, `t_backup.sh` | konfigurasi, siklus hidup stack, backup dan restore |
| `t_wings.sh`, `t_firewall.sh` | Wings, ufw, dead-man switch, egress guard, audit |
| `t_games_cli.sh`, `t_games.sh`, `t_installer.sh` | CLI game, `games.py` terhadap Panel palsu, installer modpack (juga menjalankan `test_games.py` dan `test_installer.py`) |
| `t_ext.sh` | ekstensi dan tema |
| `t_static.sh` | sintaks, render compose, pemindaian rahasia, penghapusan data, redaksi, shellcheck |
| `t_docs.sh` | tautan dan anchor dokumentasi, bagian yang dirujuk pesan di kode |

Tambahkan test pada berkas yang sesuai dengan pola yang ada: `sandbox`, `valid_config`, panggil `p <perintah>`, lalu `assert_eq`, `assert_contains`, dan seterusnya; akhiri dengan `finish`. Untuk perilaku yang bergantung pada Panel, perluas `MockPanel` di `tests/test_games.py`. Bila Anda memperbaiki bug yang ditemukan lewat pengujian nyata, tulis test yang gagal tanpa perbaikannya.

## Menaikkan versi

Panel 2.0 masih beta, jadi tiap kenaikan dibaca catatan rilisnya dulu dan migrasi tidak bisa dibalik.

1. Baca catatan rilis upstream ([Panel](https://github.com/pterodactyl/panel/releases), [Wings](https://github.com/pterodactyl/wings/releases), [cloudflared](https://github.com/cloudflare/cloudflared/releases), [mc-router](https://github.com/itzg/mc-router)).
2. Ambil digest image: `docker buildx imagetools inspect <image>:<tag>`. Salin digest `sha256:...` ke `config/versions.env` dan perbarui komentar tag di atasnya.
3. Wings: unduh `wings_linux_amd64` dan `wings_linux_arm64` dari rilis, hitung `sha256sum`, dan cocokkan dengan field `digest` pada API aset rilis GitHub. Isi `WINGS_VERSION`, `WINGS_SHA256_AMD64`, dan `WINGS_SHA256_ARM64`.
4. Jalankan `bash tests/run.sh` (semua berkas; `run.sh` menerima satu berkas atau pola sebagai argumen). `validate_config` menolak image tanpa digest dan hash yang bukan 64 heksadesimal.
5. Pada staging: `./ptero update --check`, lalu `./ptero update`, `sudo ./ptero wings update`, dan [daftar periksa verifikasi](verification.md#daftar-periksa-untuk-vps-anda).
6. Perbarui [Arsitektur](architecture.md#versi-dan-risiko-beta) (tabel versi) dan [Verifikasi](verification.md) (fakta upstream, tanggal) dengan hasil yang Anda amati, bukan yang diharapkan.

## Membangun ulang egg modpack

Egg dihasilkan dari tiga sumber: `egg.template.json`, `installer.py` (disematkan sebagai skrip install), dan `INSTALLER_IMAGE` dari `versions.env` (kontainer install).

```bash
./ptero egg build        # menulis eggs/modpack-installer/modpack-installer.egg.json
./ptero egg check        # exit 1 bila berkas yang dilacak tidak sama dengan hasil build
./ptero egg install      # mengimpor atau memperbarui egg di Panel yang berjalan
```

Jangan menyunting `modpack-installer.egg.json` dengan tangan; ubah sumbernya lalu build. `t_games.sh` memastikan berkas egg identik dengan hasil build.

## Menambah ekstensi Panel

Ikuti [Ekstensi dan tema](extensions.md#menambah-ekstensi-lain): `ext vet`, baca kodenya, tambahkan baris ke `extensions.lock`, tambahkan test bila perilaku pemasangan berubah.

## Menjaga dokumentasi

- Baca [konvensi dokumentasi](README.md#konvensi-dokumentasi). Setiap halaman punya jenis, ringkasan, dan label status verifikasi.
- Setiap klaim tentang perilaku harus bisa ditelusuri ke kode, test, atau pemeriksaan di [Verifikasi](verification.md). Klaim yang belum dijalankan diberi label **belum diuji**.
- Keluaran pada halaman Tutorial diambil dari pesan di `lib/*.sh`. Bila Anda mengubah pesan, ubah dokumennya.
- Pesan di kode menunjuk ke bagian dokumen tertentu (`architecture.md` "Versi dan risiko beta", `operations.md` "Wings", "Rollback", "Backup"). `t_docs.sh` memeriksa bagian itu ada; ubah pesannya bila Anda mengubah judulnya.
- Tambahkan halaman baru ke tabel di [docs/README.md](README.md); `t_docs.sh` gagal bila ada halaman yang tidak diindeks atau ada tautan atau anchor yang putus.
- Tulis dalam kalimat aktif dan langsung. Hindari kata yang menekan pembaca (mudah, sederhana, cepat) dan pengisi (sangat, sekadar); ganti dengan deskripsi konkret ("satu perintah", "bawaan"). Gunakan heading kalimat-kasus, bahasa blok kode, dan placeholder yang jelas palsu (`your_token_here`).

## Hal terbuka

Daftar ini bukan janji, hanya catatan jujur tentang celah yang diketahui:

- Opsi `game create --label` tidak memengaruhi nama host yang dirutekan ([Referensi perintah](commands.md#opsi-game-create)). Perbaikannya memerlukan keputusan di mana label disimpan (misalnya di Panel).
- Menjalankan server game lewat Wings di host Linux belum diuji ([Verifikasi](verification.md#belum-diverifikasi)).
- Repositori belum memiliki berkas lisensi. Tambahkan sebelum dipublikasikan.

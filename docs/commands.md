# Referensi perintah `./ptero`

> **Jenis:** Referensi · **Untuk:** operator · **Sumber kebenaran:** `./ptero help` dan `lib/*.sh`

Halaman ini mendaftar setiap perintah `./ptero` dengan sintaks, hak akses, apa yang diubah, dan perilaku yang perlu diketahui. Perintah dijalankan dari direktori repositori. Bila Anda mencari urutan pemasangan, baca [Instalasi lengkap](installation.md); untuk prosedur pemeliharaan, [Operasi](operations.md).

## Konvensi

| Hal | Aturan |
|---|---|
| Hak akses | Perintah tanpa tanda memerlukan pengguna di grup `docker`. **root** berarti harus dijalankan dengan `sudo` dan akan menolak dengan kode 4 bila bukan root |
| `--yes` / `-y` | Opsi global yang boleh ditaruh di mana saja. Menjawab semua konfirmasi, termasuk frasa `RESTORE`. Tanpa terminal, perintah yang butuh konfirmasi gagal (kode 4) kecuali opsi ini diberikan |
| Idempoten | **ya** berarti menjalankan ulang tidak mengubah apa pun yang sudah benar |
| Validasi | Perintah yang menyentuh stack memvalidasi `config/deploy.env`, `config/versions.env`, dan `secrets/` lebih dulu, mencetak setiap masalah sekaligus, lalu keluar dengan kode 3 |
| Kode keluar | `0` ok, `1` gagal, `2` salah pakai, `3` preflight/konfigurasi tidak valid, `4` ditolak demi keamanan |
| Rahasia | Tidak pernah menjadi argumen. Diketik pada prompt tersembunyi atau dibaca dari `secrets/` |

## Pemasangan awal

| Perintah | Hak | Idempoten | Efek |
|---|---|---|---|
| `./ptero init` | | ya | membuat `config/deploy.env` (mode 600) dari contoh, `secrets/db_password` dan `secrets/redis_password` (acak), serta `backups/`. Tidak menimpa berkas yang ada. Memerlukan `openssl` |
| `./ptero tunnel set-token` | | ya (menimpa token) | meminta token pada prompt tersembunyi, memvalidasi bentuknya, menyimpan ke `secrets/tunnel_token`. Menerima seluruh baris `... --token XXXX` dan memotongnya |
| `./ptero tunnel info` | | ya | mencetak dua route yang ditambahkan di dashboard Cloudflare, sesuai konfigurasi. Hanya membaca |
| `./ptero preflight` | | ya | pemeriksaan host (OS, arsitektur, perintah, Docker dan Compose, disk, RAM, NTP, port, subnet, koneksi keluar). Hanya membaca; kode 3 bila ada `[FAIL]` |
| `./ptero setup` | | ya | preflight, `compose pull`, basis data dan cache, deteksi instalasi baru atau yang ada, `migrate --seed` **hanya** pada basis data kosong, start Panel dan tunnel, penerapan ekstensi dan tema, impor egg bila `GAMES_ENABLED=yes` |
| `./ptero admin create` | | tidak | menjalankan `p:user:make` milik Panel. Memerlukan terminal dan Panel sehat; kata sandi diketik pada prompt Panel |

`setup` menolak melanjutkan (kode 4) bila basis data berisi tabel Panel tetapi volume `panel_var` tidak punya `APP_KEY`, atau bila ada migrasi tertunda. Kegagalan memasang ekstensi atau egg hanya menjadi peringatan; Panel tetap hidup dan Anda mengulangnya dengan `ext install` atau `egg install`.

## Operasi harian

| Perintah | Hak | Efek |
|---|---|---|
| `./ptero status` | | tabel status database, cache, panel, cloudflared, mc-router (bila aktif), HTTP Panel, Wings, dan versi. Kode 1 bila ada yang tidak sehat |
| `./ptero verify` | | memeriksa jalur publik tanpa kredensial: DNS kedua host, halaman login Panel (`200`), endpoint Wings (`401`, `403`, atau `404`). Kode 1 bila ada yang gagal |
| `./ptero audit` | | daftar listener di luar loopback dan container yang menerbitkan port ke `0.0.0.0`; menandai `UNEXPECTED`. Kode 1 bila ada yang tak terduga |
| `./ptero logs [-f] [--tail N] [layanan]` | | log container (`database`, `cache`, `panel`, `cloudflared`, `mc-router`); `wings` membaca journal systemd. Bawaan `--tail 100`. `journalctl` memerlukan akses ke journal (root atau grup `systemd-journal`/`adm`) |
| `./ptero up` | | menyalakan semua layanan dan menunggu sehat (batas 300 detik). Aman diulang |
| `./ptero down` | | menghentikan container. **Semua volume dan data tetap ada.** Tidak ada perintah yang menghapus data |
| `./ptero compose <args>` | | `docker compose` dengan project, berkas, profil, variabel, dan rahasia yang benar. Untuk perintah satu kali, misalnya `./ptero compose exec panel php artisan p:user:make`. Jangan menjalankan `docker compose` langsung: variabel wajib tidak terisi |
| `./ptero diagnose [--output FILE]` | | laporan bantuan (versi, konfigurasi non-rahasia, preflight, status, ekor log, hasil `verify`) dengan rahasia disamarkan. Menolak menimpa `FILE` yang ada. Penyamaran bersifat *best effort*: baca sebelum membagikan |
| `./ptero help` / `version` | | bantuan dan versi skrip |

## Backup, pemulihan, dan pembaruan

| Perintah | Hak | Efek |
|---|---|---|
| `./ptero backup [--label NAMA]` | | membuat `backups/<waktu>-<label>/` berisi `db.sql.gz`, `panel_var.tgz`, `extensions.tgz`, `config.tgz`, `MANIFEST`, `SHA256SUMS` (bila `BACKUP_AGE_RECIPIENT` diisi, satu berkas `.tar.age`). `NAMA` harus cocok `[a-z0-9-]{1,32}`, bawaan `manual`. Direktori hanya muncul tanpa akhiran `.partial` bila semuanya selesai. Tidak pernah menghapus backup lain |
| `./ptero restore [--yes] [--identity KUNCI] [--allow-version-mismatch] [--no-safety-backup] BACKUP` | | **mengganti** basis data Panel dan `panel_var` (`APP_KEY`) dengan isi backup. Memverifikasi checksum dan `APP_KEY`, menolak bila image Panel berbeda (kecuali `--allow-version-mismatch`), meminta mengetik `RESTORE`, membuat safety backup `pre-restore` bila ada data, lalu menghentikan Panel dan tunnel selama impor. Bila impor gagal, Panel dibiarkan berhenti. Wings dan data game tidak disentuh. `--identity` untuk backup terenkripsi |
| `./ptero restore-config [--identity KUNCI] BACKUP` | | mengisi checkout **kosong** dengan `config/deploy.env` dan `secrets/*` dari backup; menolak menimpa berkas yang ada (kode 4). Config Wings disimpan sebagai `config/wings-config.restored.yml`. `versions.env` dari backup tidak diterapkan |
| `./ptero update --check` | | membandingkan container yang berjalan dengan `versions.env` dan melaporkan migrasi tertunda. Hanya membaca |
| `./ptero update` | | meminta konfirmasi, **backup wajib** (`pre-update`; gagal = berhenti), pull image, hentikan Panel, `migrate --seed`, start, tunggu sehat. Seeder menimpa egg bawaan, jadi egg yang Anda ubah harus berupa salinan. Panel mati selama beberapa menit |

Rollback sebuah update dijelaskan di [Operasi: update dan rollback](operations.md#update-dan-rollback).

## Wings (host)

| Perintah | Hak | Efek |
|---|---|---|
| `sudo ./ptero wings install [--config FILE]` | **root** | meminta konfirmasi; mengunduh biner yang dipatok dan **menolak memasangnya bila sha256 tidak cocok**; memasang `/usr/local/bin/wings` (versi lama disimpan sebagai `.prev`) dan unit `wings.service`; dengan `--config`, memeriksa dan menambal config lalu menyalakan layanan dan menunggu API (batas 180 detik). Tanpa `--config`, biner dan unit terpasang tetapi Wings belum dinyalakan |
| `sudo ./ptero wings configure FILE` | **root** | memeriksa dan menambal config dari tab *Configuration* node, memasangnya di `/etc/pterodactyl/config.yml` (mode 600, versi lama disimpan sebagai `config.yml.bak-<waktu>`), dan me-restart Wings bila aktif. Peringatan: `FILE` masih berisi token node, hapus dengan `shred -u` |
| `sudo ./ptero wings update` | **root** | mengganti biner ke versi yang dipatok setelah konfirmasi dan verifikasi sha256, lalu me-restart. Container game yang berjalan tetap berjalan |
| `./ptero wings status` | | versi biner, status layanan, versi yang dipatok, dan kode HTTP API |
| `./ptero wings logs [N]` | | `N` baris terakhir journal Wings (bawaan 100), dengan rahasia disamarkan |

Kunci yang ditambal pada config, dan alasannya, ada di [Operasi: Wings](operations.md#wings-dari-node-di-panel-sampai-hijau).

## Firewall, egress guard, dan audit

| Perintah | Hak | Efek |
|---|---|---|
| `./ptero firewall plan` | | mencetak port SSH yang terdeteksi dan aturan ufw yang akan ditambahkan. Hanya membaca |
| `sudo ./ptero firewall apply` | **root** | memeriksa risiko lock-out, mencetak rencana, meminta konfirmasi, menyimpan keadaan sebelumnya di `backups/firewall-before-<waktu>.txt`, menambah aturan (SSH lebih dulu), `default deny incoming`, menyalakan ufw, memverifikasi bahwa tiap port SSH diterima (bila tidak, ufw dimatikan lagi seketika), lalu memasang dead-man switch. Menolak (kode 4) bila ufw mati dan `systemd-run` tidak ada, kecuali `FIREWALL_ROLLBACK_SECONDS=0` |
| `sudo ./ptero firewall confirm` | **root** | membatalkan dead-man switch. Jalankan dari sesi SSH **baru** |
| `./ptero firewall status` | | `ufw status verbose` dan timer dead-man switch yang tertunda |
| `sudo ./ptero firewall egress apply [--quiet]` | **root** | memasang aturan egress guard sekarang (rantai `DOCKER-USER` dan `INPUT`). Memakai subnet dari config Wings bila ada, jika tidak `GAME_NET_SUBNET` |
| `sudo ./ptero firewall egress install` | **root** | memasang unit `ptero-egress-guard.service` sehingga aturan dipasang ulang setiap boot setelah Docker menyala |
| `./ptero firewall egress status` | | memeriksa tiap aturan; kode 1 bila ada yang hilang |

Jika ufw sudah aktif sebelum `apply`, aturan hanya ditambah dan tidak ada dead-man switch. Perintah ini tidak pernah menghapus aturan Anda. Rancangan lengkapnya: [Arsitektur](architecture.md#matriks-port-dan-firewall) dan [Keamanan](security.md).

## Ekstensi dan tema Panel

| Perintah | Hak | Efek |
|---|---|---|
| `./ptero ext list` | | tabel ekstensi terkunci, versi terkunci, versi terpasang, dan apakah diminta; tema yang diminta dan aktif |
| `./ptero ext install [--no-backup]` | | menerapkan keadaan yang diminta (`PANEL_EXTENSIONS`, `PANEL_THEME`). Backup `pre-extensions` lebih dulu bila ada yang akan dipasang di Panel berisi; gagal backup = tidak ada yang disentuh. Tidak pernah menghapus ekstensi. Idempoten |
| `./ptero ext vet FILE` | | memeriksa paket (id, versi, sha256, panggilan PHP berbahaya) tanpa memasang. Penyaring awal, bukan bukti keamanan |

## Server Minecraft

Perintah ini memerlukan `GAMES_ENABLED=yes`. Panduan penuh: [Server Minecraft](games.md).

| Perintah | Hak | Efek |
|---|---|---|
| `./ptero key set {panel\|client\|curseforge}` | | menyimpan kunci API pada prompt tersembunyi ke `secrets/`: `panel` = Application API (`ptla_`), `client` = Client API (`ptlc_`, untuk verifikasi install), `curseforge` = kunci CurseForge Anda. Bentuk kunci divalidasi |
| `./ptero egg build` | | membangun `modpack-installer.egg.json` dari templat dan `installer.py` |
| `./ptero egg check` | | memeriksa bahwa berkas egg yang dihasilkan sama dengan hasil build dari sumber; kode 1 bila beda |
| `./ptero egg install` | | mengimpor atau memperbarui egg "Minecraft Modpack (CurseForge / Modrinth)" di Panel lewat aksi impor milik Panel. Kunci CurseForge yang tersimpan tidak terhapus |
| `./ptero game create ...` | | rencana, konfirmasi, lalu membuat alokasi, server, menunggu install, memverifikasi `launch.args` (bila ada kunci client), dan menulis rute nama host |
| `./ptero games sync [--quiet]` | | membangun tabel nama host dari daftar server di Panel dan menulis `runtime/mc-router/routes.json`. Router dimuat ulang hanya bila tabel berubah; tabel dibiarkan bila Panel tidak terjangkau |
| `./ptero games list` | | nama host dan port tiap server |
| `./ptero games status` | | status mc-router, apakah port game mendengar (diperiksa dari container jaringan host), dan jumlah rute. Kode 1 bila ada masalah |
| `./ptero games dns` | | mencetak satu record DNS wildcard (A, *DNS only*) yang perlu dibuat |
| `sudo ./ptero games timer install` / `remove` | **root** | memasang atau mencabut timer systemd yang menyinkronkan nama host setiap 2 menit. Rute yang sudah ditulis tetap ada setelah dicabut |

### Opsi `game create`

| Opsi | Wajib | Bawaan | Arti |
|---|---|---|---|
| `--name NAMA` | ya | | nama server di Panel; slug-nya (huruf kecil, karakter selain huruf dan angka menjadi `-`, maksimum 40 karakter) menjadi label nama host: `Survival Utama` → `survival-utama.GAMES_DOMAIN` |
| `--source {modrinth\|curseforge\|url}` | ya | | asal modpack |
| `--pack SLUG` | ya | | slug Modrinth, slug atau id numerik CurseForge, atau tautan https ke `.mrpack` atau zip server-pack |
| `--version V` | tidak | rilis terbaru | versi atau id berkas pack |
| `--mc VERSI` | tidak | dari pack | filter versi Minecraft |
| `--loader {fabric\|forge\|neoforge\|quilt}` | tidak | dari pack | harus cocok dengan pack; pack yang menentukan |
| `--memory MB` | tidak | otomatis dari jumlah mod: kurang dari 120 mod = 4096, 120 sampai 199 = 6144, 200 atau lebih = 8192, jumlah tidak diketahui = 6144 | batas RAM; ditolak (kode 3) bila total RAM server di node melebihi kapasitas node |
| `--disk MB` | tidak | `20480` | batas disk |
| `--cpu PERSEN` | tidak | `400` | batas CPU |
| `--port P` | tidak | alokasi `127.0.0.1` bebas pertama di rentang backend; bila tidak ada, port pertama yang belum terpakai (alokasinya dibuat) | harus di dalam `GAMES_BACKEND_FIRST` sampai `GAMES_BACKEND_LAST` |
| `--owner EMAIL` | tidak | `ADMIN_EMAIL` | pemilik server; harus pengguna Panel dengan email itu |
| `--label L` | tidak | slug dari nama server | **cacat yang diketahui:** hanya memengaruhi alamat yang ditampilkan di rencana dan pemeriksaan bentrok. Rute yang ditulis (`games sync`, `game create`) selalu memakai slug nama server, jadi nama host tidak mengikuti `--label`. Beri server nama yang menghasilkan nama host yang Anda inginkan |
| `--no-wait` | tidak | menunggu | tidak menunggu dan tidak memverifikasi install |

Tanpa konfirmasi, `game create` hanya menampilkan rencana dan tidak membuat apa pun. Nama server atau nama host yang sudah dipakai ditolak (kode 3) sebelum apa pun dibuat. Server dibuat dengan batas fitur `databases: 0`, `allocations: 0`, `backups: 3`, dan tidak dinyalakan otomatis. Bila verifikasi `launch.args` gagal, perintah berhenti dengan kode 1 **sebelum** menulis rute nama host; servernya tetap ada di Panel untuk diperbaiki.

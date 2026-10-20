# Analisis Dokumentasi Pterodactyl 2.0 (docs.pterodactyl.io/v2)

Dokumentasi di https://docs.pterodactyl.io/v2 adalah panduan untuk **Pterodactyl Panel 2.0 yang masih berstatus *open beta*** (rilis terbaru yang dirujuk: `v2.0.0-beta.2`).\[1\] Isinya rapi dan praktis, tetapi beberapa halaman saling bertentangan dan banyak skenario belum diuji. Saran utama: gunakan 2.0 untuk uji coba atau instalasi baru yang tidak kritis. Untuk produksi, ikuti anjuran catatan rilis v2.0.0-beta.1 untuk tetap memakai 1.x (rilis stabil terbaru v1.15.1, 14 Agustus) sampai 2.0 stabil, atau upgrade hanya setelah mencobanya pada salinan Panel.

## TL;DR
- **Apa ini:** Pterodactyl adalah panel manajemen game server open-source (PHP/Laravel + React + Go). Ada dua komponen: **Panel** (situs web untuk mengelola) dan **Wings** (daemon Go di setiap node yang menjalankan server dalam container Docker). Versi 2.0 menambahkan **extensions**, **themes**, **admin area baru**, dan **tags** sebagai pengganti *nests*.
- **Instalasi/upgrade:** Panel 2.0 butuh PHP 8.3/8.4 (wajib ekstensi `intl`), MariaDB 10.11/11 atau MySQL 8/9, Redis, dan Composer 2. Wings tetap sama dengan 1.x (halaman Installing Wings menyatakan Wings 1.13.2–1.13.4 sudah diuji; v1.13.4 dirilis 2026-10-14 menurut daftar Updates pterodactyl.io). Upgrade dari 1.x **wajib** memakai metode direktori paralel. Jangan pakai `php artisan p:upgrade`, dan cadangkan `APP_KEY`.
- **Risiko utama:** status beta; menurut bagian Known Limitations di halaman Upgrading From 1.x, panduan upgrade baru diuji dengan Panel 1.15.1, MariaDB 10.11, dan Wings 1.13.2 di Ubuntu 24.04; endpoint `/api/application/nests/...` dihapus sehingga modul billing lama rusak; dan ada beberapa inkonsistensi antarhalaman (versi Wings, langkah npm, status rilis).

## Cakupan dan Keterbatasan Penelusuran

Halaman yang saya baca utuh: indeks /v2, Getting Started, Updating the Panel, Upgrading From 1.x, Installing Wings, Extensions, Troubleshooting, Additional Configuration, dan satu halaman referensi API (Admin API "Import egg", yang sidebarnya memuat daftar lengkap endpoint Admin API). Halaman lain saya ringkas dari cuplikan hasil mesin pencari yang terindeks (How It Works, Introduction, Upgrading PHP, Setting Up MySQL, Docker Images, Building Wings, Themes, beberapa halaman API Client/Application).

**Halaman yang tidak bisa diakses langsung.** Penyebabnya bukan error server: alat riset saya hanya boleh membuka URL yang muncul di hasil pencarian, dan halaman-halaman ini tidak pernah muncul. Saya juga tidak menemukan halaman FAQ atau changelog tersendiri di /v2. Daftarnya:
- https://docs.pterodactyl.io/v2/api (API Overview)
- https://docs.pterodactyl.io/v2/upgrading/changes-from-v1
- https://docs.pterodactyl.io/v2/upgrading/testing-the-upgrade
- https://docs.pterodactyl.io/v2/panel/requirements
- https://docs.pterodactyl.io/v2/panel/docker
- https://docs.pterodactyl.io/v2/panel/webserver-configuration
- https://docs.pterodactyl.io/v2/wings/configuration
- https://docs.pterodactyl.io/v2/wings/upgrading
- https://docs.pterodactyl.io/v2/extensions/building, /backend, /frontend, /data-and-styling, /testing-and-packaging, /reference
- https://docs.pterodactyl.io/v2/project/about, /community, /using-ai
- Sebagian besar dari 16 halaman Community Guides (misalnya SSL certificates, creating a node, mounts, Minecraft proxy networks, egg variables/startup)

Isi halaman-halaman ini hanya saya simpulkan dari rujukan di halaman lain, dan saya tandai demikian. Verifikasi sendiri sebelum mengandalkannya.

## Key Findings

### 1. Peta Struktur Dokumentasi

Menurut halaman induk https://docs.pterodactyl.io/, dokumentasi 2.0 terdiri dari: Project (5 halaman), Panel (7), Wings (3), Extensions (7), Upgrading from 1.x (3), Community guides (16), dan API reference (233 halaman, dihasilkan otomatis dari spesifikasi API).\[2\]

| Bagian | Halaman (URL di bawah /v2) | Fungsi |
|---|---|---|
| Indeks | /v2 | Titik masuk, peringatan beta, larangan memakai langkah 1.x / `p:upgrade`\[1\] |
| Project | /project, /project/how-it-works, /project/about, /project/community, /project/using-ai | Pengenalan, arsitektur & istilah, port, standar komunitas, panduan memakai AI |
| Panel | /panel/requirements, /panel/getting-started, /panel/docker, /panel/webserver-configuration, /panel/additional-configuration, /panel/updating, /panel/troubleshooting | Instalasi, konfigurasi, pembaruan, pemecahan masalah |
| Wings | /wings/installing, /wings/configuration, /wings/upgrading | Menyiapkan node |
| Extensions | /extensions, /extensions/building, /backend, /frontend, /data-and-styling, /testing-and-packaging, /reference | Memakai dan membangun ekstensi |
| Upgrading From 1.x | /upgrading/changes-from-v1, /upgrading/upgrading-from-v1, /upgrading/testing-the-upgrade | Migrasi 1.x → 2.0 |
| Community Guides | /guides/tutorials/ssl-certificates, /guides/tutorials/mysql-setup, /guides/configuration/php-upgrade, /guides/egg-creation/creating-custom-egg, /guides/egg-creation/egg-docker-images, /guides/customization/themes, /guides/customization/wings, /guides/games/minecraft, dll. | Tutorial tambahan |
| API Reference (2.0) | /api, /api/admin-api/*, /api/application-api/*, /api/client-api/* | Referensi endpoint |

**Alur antarhalaman:** Requirements → Getting Started (atau Docker) → Webserver Configuration → Installing Wings (membuat node + allocation) → Additional Configuration.\[3\] Untuk pengguna 1.x: Changes From 1.x → Testing the Upgrade → Upgrading From 1.x. Troubleshooting menjadi pusat rujukan silang ke hampir semua halaman lain.

### 2. Arsitektur dan Komponen

Sumber: https://docs.pterodactyl.io/v2/project/how-it-works dan https://docs.pterodactyl.io/v2/project

- **Panel**: aplikasi web Laravel di belakang NGINX/Apache/Caddy dengan PHP. Data disimpan di MariaDB/MySQL, dan Redis dipakai untuk sesi, cache, dan antrean. Panel tidak pernah terhubung langsung ke game server.\[4\]
- **Wings**: layanan Go di setiap node. Wings menjalankan server dalam Docker, mengalirkan konsol ke browser, dan melayani file via SFTP.\[4\] (Istilah "Daemon" hanya muncul pada nama unit systemd "Pterodactyl Wings Daemon" dan "Daemon Port"; secara praktis Daemon = Wings.)\[5\]
- **Node**: mesin yang menjalankan Wings. Panel dan Wings boleh berada di mesin yang sama.\[4\]
- **Server / Container / Docker image (yolks) / Egg**: tiap server berjalan di container sendiri dengan batas CPU/memori/disk. Egg mendefinisikan image, perintah startup, variabel, dan skrip instalasi.\[4\]
- **Tag** (baru di 2.0): label pada egg dan node yang mengelompokkan egg dan menentukan node tujuan deploy. Tag menggantikan *nests*.\[4\]
- **Extension** (baru di 2.0): paket yang menambah fitur Panel.\[4\]

**Port default:**

| Dari → Ke | Port | Kegunaan |
|---|---|---|
| Browser → Panel | 443 (80 tanpa SSL) | Situs Panel |
| Browser → Wings | 8080 | Konsol (websocket), unggah/unduh file |
| Klien SFTP → Wings | 2022 | File server |
| Panel → Wings | 8080 | Membuat server, file, instalasi, backup |
| Wings → Panel | 443/80 | Pengaturan server, hasil, login SFTP |
| Pemain → Game server | Port allocation | Bermain\[4\] |

Implikasinya: game server tetap berjalan ketika Panel mati, karena yang menjalankannya adalah Wings. Jika Panel memakai HTTPS, setiap node juga wajib punya sertifikat SSL sendiri.\[4\] Ini sumber masalah konsol paling umum.

### 3. Instalasi dan Prasyarat

**Panel.** Sumber: https://docs.pterodactyl.io/v2/panel/getting-started
- OS yang didukung: Ubuntu 26.04 / 24.04 (direkomendasikan, sudah membawa PHP 8.3) / 22.04, serta Debian 13 / 12. Distro lain "mungkin berjalan" tetapi tidak didukung. Image Docker resmi juga didukung.\[3\]
- Dependensi: PHP 8.3 atau 8.4 + ekstensi `cli, gd, mysql, mbstring, bcmath, xml, curl, zip, intl` (PHP-FPM untuk NGINX/Caddy); MariaDB 10.11/11 atau MySQL 8/9; Redis; Composer 2; curl, tar, unzip.\[3\]
- Langkah utama: unduh `panel.tar.gz` dari rilis `v2.0.0-beta.2` ke `/var/www/pterodactyl` → buat database `panel` dan user `pterodactyl@127.0.0.1` → `composer install --no-dev --optimize-autoloader` → `php artisan key:generate --force` (hanya untuk instalasi baru) → `p:environment:setup`, `p:environment:database`, `p:environment:mail` (pilih Redis untuk cache/sesi/antrean, SMTP untuk email) → `php artisan migrate --seed --force` → `p:user:make` → `chown www-data` → cron `schedule:run` setiap menit + layanan systemd `pteroq` (`queue:work --queue=high,standard,low`).\[3\]
- **Peringatan terpenting:** `APP_KEY` di `.env` mengenkripsi API key, token node, dan rahasia 2FA. Jika hilang, data itu tidak bisa dipulihkan, bahkan dari backup database. Simpan salinannya di luar server.\[3\]
- Telemetri anonim aktif secara default (lihat bagian Additional Configuration).\[3\]

**Wings.** Sumber: https://docs.pterodactyl.io/v2/wings/installing
- OS: Ubuntu 22.04/24.04/26.04, Debian 12/13. Tidak berjalan di Windows. Menurut halaman Installing Wings, Wings kemungkinan besar tidak berjalan pada virtualisasi Virtuozzo, OpenVZ, atau LXC (sebagian penyedia tetap mendukung Docker, jadi tanyakan), sedangkan KVM selalu berhasil (periksa dengan `systemd-detect-virt`).
- Instal Docker (`get.docker.com`), aktifkan saat boot, dan aktifkan `swapaccount=1` hanya jika kernel < 6.1. Hindari kernel modifikasi host (akhiran `-grs-ipv6-64` / `-mod-std-ipv6-64`).\[5\]
- Unduh biner `wings_linux_amd64/arm64` → buat node di **Admin → Nodes** → konfigurasikan via perintah auto-deploy `wings configure --panel-url … --token … --node N` (tambahkan `--override` untuk menimpa) atau salin `config.yml` ke `/etc/pterodactyl/config.yml` → uji dengan `wings --debug` → jalankan sebagai `wings.service`.\[5\]
- **Allocation** = pasangan IP + port. Setiap server butuh minimal satu. Jangan memakai `127.0.0.1` untuk allocation yang diakses pemain.\[5\]

**Docker untuk Panel.** Image ini sudah memuat web server, queue worker, dan scheduler, dan di-deploy dengan Docker Compose.\[3\] Detail nama image dan variabel lingkungannya ada di /v2/panel/docker, yang tidak bisa saya buka. Halaman Extensions menyebut volume yang wajib dipertahankan: `/app/extensions` dan `/app/public/assets/extensions`.\[6\]

### 4. Upgrade dari 1.x dan Pembaruan dalam 2.x

**Upgrade 1.x → 2.0.** Sumber: https://docs.pterodactyl.io/v2/upgrading/upgrading-from-v1
- Syarat: Panel 1.12.0+, PHP ≥ 8.3 + `intl`, dan modul billing yang sudah diperbarui (modul WHMCS resmi yang diperbarui berfungsi dengan 1.x maupun 2.0; README github.com/pterodactyl/whmcs menegaskan versi lama modul tidak bisa membuat server atau mengubah paket di 2.x).
- Metode: daftar periksa 12 langkah. Masuk mode maintenance → backup (mysqldump, `.env`, tarball file) → unduh 2.0 ke `/var/www/pterodactyl-2.0` → salin `.env` (**jangan** jalankan `key:generate`) → `composer install` → `php artisan migrate --force` (menambah tabel tags/extensions tanpa mengubah data lama; `db:seed` kini opsional) → tukar direktori (yang lama menjadi `/var/www/pterodactyl-1.x`) → tambahkan blok `location ^~ /assets/` di NGINX → `optimize:clear`, restart PHP-FPM dan `pteroq` → `php artisan up`.\[7\]
- Yang tetap sama: cron, `pteroq`, `.env` (nama variabel 1.x seperti `CACHE_DRIVER` masih dibaca), pengguna/2FA/SSH key, API key lama, server/subuser/jadwal/backup/database/SFTP, dan pengaturan.\[7\]
- Konversi nests → tags: nest bernama game bawaan memberi tag game tersebut; nest kustom dengan ≥ 2 egg menjadi tag bernama sama; nest kustom dengan 1 egg **tidak** menjadi tag, sehingga egg-nya kehilangan pengelompokan. Tabel `nests` tetap ada tetapi tidak lagi diperbarui.\[7\]
- Rollback: tukar kembali direktori dan pulihkan dump SQL. `migrate:rollback` tidak bisa membatalkan upgrade. Server, backup, dan rotasi password database yang dibuat di 2.0 tetap tertinggal di node/storage.\[7\]
- Error "missing 1.x migration" berarti 1.x belum diperbarui. Belum ada yang diubah, jadi perbarui 1.x dulu lalu ulangi dari awal.\[7\]

**Pembaruan dalam 2.x.** Sumber: https://docs.pterodactyl.io/v2/panel/updating
Urutannya: maintenance → unduh rilis dan ekstrak di atas file lama → `composer install` → `view:clear` dan `config:clear` → `migrate --seed --force` (seeder **menimpa egg bawaan**, jadi salin dulu egg yang ingin Anda modifikasi) → `chown` → `queue:restart` → `up`. Halaman ini juga memperingatkan bahwa `p:upgrade` tanpa `--release` akan mengunduh rilis 1.x dan merusak Panel 2.0.\[8\]

**Upgrade PHP.** Sumber: https://docs.pterodactyl.io/v2/guides/configuration/php-upgrade
Panel 2.x butuh PHP 8.3/8.4, sedangkan 1.11.10–1.x memakai 8.2/8.3.\[9\] Setelah upgrade PHP, ubah socket PHP-FPM di konfigurasi NGINX, lalu periksa dengan `composer check-platform-reqs --no-dev`.\[9\]

### 5. Fitur dan Cara Kerja Utama

- **Node & allocation:** dibuat di Admin → Nodes (tab Configuration untuk token auto-deploy, tab Allocation untuk IP:port). Port 8080/2022 bisa diubah per node.\[4\]\[5\] Lewat API, node bisa diberi tag game dan tag deployment.\[4\]\[5\]\[10\]
- **Server:** dibuat dari egg dengan batas memori/CPU/disk dan *feature limits* (jumlah database, allocation, backup). Pengguna bisa mengganti Docker image di antara pilihan yang disediakan egg lewat halaman Startup. Format image `Nama|image`, dan awalan `~` untuk image lokal (https://docs.pterodactyl.io/v2/guides/egg-creation/egg-docker-images). \[10\]\[11\]
- **User & permission:** subuser mendapat izin granular. Contohnya, akses SFTP butuh izin SFTP, sementara pemilik dan admin selalu memilikinya. Format username SFTP: `username.8charID` di port 2022 (https://docs.pterodactyl.io/v2/panel/troubleshooting). \[12\]
- **Database host:** server MariaDB tempat Panel membuat database per server. Butuh user tersendiri (jangan pakai ulang user Panel) dan MariaDB yang mendengarkan di luar 127.0.0.1.\[13\] `PTERODACTYL_CLIENT_DATABASES_ALLOW_RANDOM=false` mencegah Panel memilih host yang tidak ditautkan ke node (https://docs.pterodactyl.io/v2/guides/tutorials/mysql-setup). \[13\]
- **Backup:** driver `wings` (lokal, `system.backup_directory`) atau `s3` (variabel `AWS_*`, multipart hingga 5 GB per bagian, URL presigned 60 menit, `AWS_BACKUPS_STORAGE_CLASS`) (https://docs.pterodactyl.io/v2/panel/additional-configuration). \[14\]
- **Keamanan:** reCAPTCHA (kunci bawaan dipakai bersama, sebaiknya ganti dengan kunci sendiri), wajib 2FA global, `p:user:disable2fa`, `TRUSTED_PROXIES` untuk reverse proxy/Cloudflare.\[14\]
- **Extensions:** paket `.pteroext` (zip) dengan `extension.json`, maksimal 50 MB lewat admin area atau via `p:extension:install|enable|disable|remove|list`. Saat diaktifkan, Panel memeriksa versi dan dependensi, menjalankan migrasi, lalu mempublikasikan aset. Menghapus ekstensi **tidak** menghapus tabel `ext_*` miliknya. Gagal update akan memulihkan paket lama, tetapi tidak membatalkan perubahan skema. `PTERODACTYL_EXTENSIONS_ENABLED=false` adalah saklar darurat. **Ekstensi berjalan dengan akses penuh Panel**, jadi instal hanya dari pengembang tepercaya (https://docs.pterodactyl.io/v2/extensions). \[6\]
- **Themes:** folder kecil berisi CSS untuk warna, kelengkungan sudut, dan warna konsol, tanpa perlu build ulang. Daftar tema bisa dilihat dengan `p:theme:list` (https://docs.pterodactyl.io/v2/guides/customization/themes). \[15\]

### 6. Dokumentasi API

Sumber: halaman referensi seperti https://docs.pterodactyl.io/v2/api/admin-api/adminImportEgg, https://docs.pterodactyl.io/v2/api/client-api/clientCreateAccountAPIKey, https://docs.pterodactyl.io/v2/api/application-api/applicationDeleteNodeAllocation. Halaman Overview (/v2/api) tidak bisa saya buka.

2.0 memiliki **tiga** API\[1\] (1.x hanya dua):\[1\]

| API | Prefix | Token yang diterima | Cakupan |
|---|---|---|---|
| **Client API** | `/api/client` | Client API key (`ptlc_…`) | Akun (2FA, email, password, aktivitas, API key, SSH key); server: websocket, resource, perintah, power, database, file, jadwal & task, allocation, subuser, backup, startup, rename, reinstall, Docker image\[16\] |
| **Application API** | `/api/application` | Application key, atau client key milik *root administrator* | Users (termasuk lookup external ID), nodes & allocations, deployable nodes, locations, eggs & tags (baca), servers (details/build/startup/suspend/reinstall)\[17\] |
| **Admin API** (baru) | `/api/admin` | **Hanya** client key milik root admin; application key ditolak | Ekstensi, bahasa, users, nodes (system info, deploy token, utilisasi, sinkron tag), servers (transfer, rebuild, force delete, mount, database, backup lock), locations, mounts, egg catalog/import/export/variabel/skrip, tags (CRUD penuh), settings (general/mail/advanced), database hosts, API keys, versi\[10\]\[17\]\[18\]\[19\]\[20\] |

**Pola penggunaan:** header `Authorization: Bearer <token>`, respons JSON berbentuk `{object, attributes, relationships, meta}`, daftar dipaginasi, dan rahasia token hanya ditampilkan sekali saat dibuat (`meta.secret_token`). API key bisa dibatasi ke IP tertentu (`allowed_ips`).\[16\] Application key memiliki izin per sumber daya (`r_servers`, `r_nodes`, `r_eggs`, dst.).\[10\]\[19\] Server diidentifikasi dengan ID numerik di Application/Admin API, dan dengan UUID atau identifier 8 karakter di Client API. **Endpoint `/api/application/nests/...` dihapus** dan digantikan oleh tags.\[7\] Konsol berjalan lewat websocket langsung ke Wings, memakai kredensial yang diambil dari `GET /api/client/servers/{server}/websocket`.\[12\]\[21\] Batas rate dan header-nya tidak berhasil saya verifikasi dari dokumen resmi /v2.

## Hal yang Tidak Jelas, Bertentangan, atau Usang

1. **Kompatibilitas Wings tidak konsisten:** Upgrading From 1.x menyatakan Wings 1.13.2 dan 1.13.3 berfungsi dengan Panel 2.0 dan Wings bisa di-upgrade belakangan, sedangkan Installing Wings menyebut 1.13.2–1.13.4 sudah diuji.
2. **Status rilis membingungkan:** halaman Updating menyatakan `p:upgrade` "hanya memasang rilis, dan 2.0 belum punya", padahal halaman yang sama dan halaman lain mengunduh rilis GitHub `v2.0.0-beta.2`. Versi lama halaman ini yang masih terindeks mesin pencari bahkan menyuruh mengunduh branch `2.0-develop` dan menjalankan `npm ci` / `npm run build:production`.\[8\] Jadi isi halaman ini berubah cepat, dan cache pihak ketiga bisa menyesatkan.
3. **Langkah npm hantu:** daftar periksa upgrade menulis "Composer, then npm", tetapi langkah rinciannya hanya menjalankan Composer.\[7\]
4. **Galat salin-tempel di referensi API:** parameter `identifier` pada `GET /api/admin/api-keys/{identifier}` dideskripsikan sebagai "server UUID or short UUID", dan contoh respons client key menampilkan identifier berawalan `ptla_`.\[16\]\[19\] Ini tampaknya artefak dari spesifikasi yang dihasilkan otomatis.
5. **Perbedaan verb HTTP:** pembaruan di Application API memakai `PATCH`, sedangkan Admin API memakai `PUT`.\[10\]\[17\] Hal ini perlu dicatat oleh pembuat integrasi.
6. **Cakupan uji upgrade sempit:** MySQL, database besar, migrasi native → Docker, HTTPS, multi-node, transfer server, backup S3, dan ekstensi **belum diuji** menurut halaman itu sendiri.\[7\]
7. **Celah konten:** tidak ada FAQ atau changelog di /v2 (pembaca diarahkan ke release notes GitHub). Konsep "locations" masih ada di API dan telemetri, tetapi tidak dijelaskan di glosarium How It Works.
8. **Dokumen 1.x yang tertaut terlihat usang:** tabel kompatibilitas di /v1/wings/upgrading berhenti di Panel 1.11.x, padahal 2.0 mensyaratkan 1.12.0+.\[7\]\[22\]

## Recommendations

**Untuk instalasi baru:**
1. Pilih **Ubuntu 24.04 + PHP 8.3 + NGINX + MariaDB 10.11**, yaitu satu-satunya kombinasi yang benar-benar diuji tim.\[7\] Siapkan domain terpisah untuk Panel dan setiap node, beserta sertifikat SSL untuk keduanya sejak awal.
2. Segera setelah `key:generate`, simpan `APP_KEY` di password manager. Jadikan backup harian berupa *pasangan* "dump DB + `.env`".
3. Buka port 443 (Panel), 8080 dan 2022 (Wings), serta rentang port allocation di firewall.\[12\] Matikan proxy Cloudflare (oranye) untuk domain Wings.
4. Ganti kunci reCAPTCHA bawaan, wajibkan 2FA untuk admin, dan atur `TRUSTED_PROXIES` jika Panel berada di belakang proxy. Matikan telemetri (`PTERODACTYL_TELEMETRY_ENABLED=false`) jika kebijakan privasi Anda menuntutnya.\[14\]

**Untuk pengguna 1.x:**
5. Jangan upgrade produksi sekarang kecuali Anda siap dengan status beta. Jika tetap ingin, ikuti urutan ini: perbarui ke 1.x terbaru → pasang `php8.3-intl` → perbarui modul WHMCS/billing → uji di salinan (Testing the Upgrade) → upgrade dengan metode direktori paralel → periksa tag egg (terutama nest yang hanya berisi 1 egg) → simpan `/var/www/pterodactyl-1.x` sampai yakin.\[7\]
6. Audit semua integrasi yang memanggil `/api/application/nests/...` dan alihkan ke endpoint eggs/tags.\[7\]

**Untuk pemeliharaan rutin:**
7. Perbarui Panel 2.x secara manual dengan menentukan versi secara eksplisit. Jangan jalankan `p:upgrade` tanpa `--release` selama 2.0 belum stabil. Jangan mengedit egg bawaan, karena seeder akan menimpanya.
8. Instal ekstensi hanya dari sumber tepercaya, uji dulu di staging, dan backup DB sebelum update ekstensi (migrasi tidak bisa dibatalkan). Ingat bahwa `PTERODACTYL_EXTENSIONS_ENABLED=false` adalah saklar darurat.
9. Biasakan alur diagnosis dari halaman Troubleshooting: log Laravel di `storage/logs`, `journalctl -u wings`, dan `wings diagnostics`. Masalah umum: 502 berarti socket PHP-FPM salah; error CSRF/419 berarti `APP_URL` tidak cocok; "Invalid MAC" berarti `APP_KEY` salah; server tanpa internet biasanya karena DNS 1.1.1.1 diblokir; jadwal tidak berjalan berarti cron, `pteroq`, atau zona waktu bermasalah.\[12\]
10. Untuk integrasi otomasi, pakai Client API untuk aksi atas nama pengguna, Application API untuk provisioning (seperti billing), dan Admin API hanya bila perlu fungsi admin baru.\[2\] Batasi setiap key ke IP tertentu dan beri izin minimum.

## Caveats
- Dokumentasi ini sendiri berstatus beta dan berubah cepat (menurut halaman GitHub Releases pterodactyl/panel, v2.0.0-beta.1 dan v2.0.0-beta.2 sama-sama dirilis pada 14 Oktober 2026, yang kedua sebagai rilis perbaikan bug; image Docker-nya `ghcr.io/pterodactyl/panel:v2.0.0-beta.2`). Angka versi dan langkah di atas bisa berubah. Selalu bandingkan dengan halaman langsung dan release notes GitHub.
- Ringkasan untuk halaman yang tidak dapat dibuka (API Overview, Changes From 1.x, Docker, Requirements, Wings Configuration, Building Extensions, dan sebagian besar Community Guides) disusun dari rujukan silang dan cuplikan mesin pencari, jadi bisa tidak lengkap.
- Sumber pihak ketiga tentang API Pterodactyl (misalnya situs dokumentasi API komunitas) umumnya membahas 1.x dan tidak saya jadikan dasar untuk klaim tentang 2.0.\[23\]

## Sources

1. [Pterodactyl 2.0 - Pterodactyl Documentation](https://docs.pterodactyl.io/v2)
2. [Pterodactyl Documentation](https://docs.pterodactyl.io/)
3. [Getting Started - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/panel/getting-started)
4. [How Pterodactyl Works - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/project/how-it-works#terms)
5. [Installing Wings - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/wings/installing)
6. [Extensions - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/extensions)
7. [Upgrading From 1.x - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/upgrading/upgrading-from-v1)
8. [Updating the Panel - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/panel/updating)
9. [Upgrading PHP - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/guides/configuration/php-upgrade)
10. [Import egg - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/api/admin-api/adminImportEgg)
11. [Docker Images - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/guides/egg-creation/egg-docker-images)
12. [Troubleshooting - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/panel/troubleshooting)
13. [Setting Up MySQL - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/guides/tutorials/mysql-setup)
14. [Additional Configuration - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/panel/additional-configuration)
15. [Themes - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/guides/customization/themes)
16. [Create account API key - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/api/client-api/clientCreateAccountAPIKey)
17. [Delete node allocation - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/api/application-api/applicationDeleteNodeAllocation)
18. [Create server backup - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/api/client-api/clientCreateServerBackup)
19. [Get API key - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/api/admin-api/adminGetAPIKey)
20. [Delete node - Pterodactyl Documentation](https://docs.pterodactyl.io/v2/api/admin-api/adminDeleteNode)
21. [Pterodactyl · Game servers, handled.](https://docs.pterodactyl.io/v0.5.0)
22. [Upgrading Wings - Pterodactyl Documentation](https://docs.pterodactyl.io/v1/wings/upgrading)
23. [Account Management](https://pteroapi.com/docs/api/client/account)

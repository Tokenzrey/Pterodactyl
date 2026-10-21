# Referensi konfigurasi

> **Jenis:** Referensi · **Untuk:** operator dan pemelihara · **Sumber kebenaran:** `config/deploy.env.example`, `config/versions.env`, dan aturan validasi di `lib/config.sh`

Halaman ini mendaftar setiap variabel konfigurasi, rahasia, berkas, volume, dan variabel lingkungan yang dipakai `./ptero`, lengkap dengan nilai bawaan, aturan validasi persis, dan efeknya. Bila dokumen dan kode berbeda, kodenya yang benar; `./ptero preflight` mencetak setiap pelanggaran aturan di bawah ini sekaligus beserta cara memperbaikinya.

## Sintaks berkas konfigurasi

`config/deploy.env` dan `config/versions.env` di-*parse*, bukan di-`source`. Nilai seperti `$(perintah)` tidak pernah dieksekusi.

| Aturan | Rincian |
|---|---|
| Format baris | `KEY=value`, dengan `KEY` berupa huruf besar, angka, dan garis bawah, diawali huruf |
| Karakter yang diizinkan di nilai | huruf, angka, dan `. _ : / @ , + = % -` (nilai lain ditolak dengan nomor barisnya) |
| Komentar | baris yang diawali `#`, atau ` #` setelah nilai tanpa tanda kutip |
| Kutip | nilai boleh diapit `"..."` atau `'...'`; isi sampai kutip penutup yang dipakai |
| Akhir baris | CRLF diterima (karakter `\r` dibuang) |
| Kunci yang tidak dikenal | diabaikan, tidak ada peringatan |

## `config/deploy.env`: variabel Anda

`./ptero init` membuat berkas ini dari `deploy.env.example` (mode 600). Berkas ini tidak dilacak Git. Kolom **Wajib** berarti tidak punya bawaan yang valid.

### Identitas

| Variabel | Bawaan | Wajib | Aturan validasi | Efek |
|---|---|---|---|---|
| `PANEL_FQDN` | kosong | ya | nama host publik valid (huruf kecil, label dipisah titik, TLD 2 sampai 63 huruf); `example.com/org/net`, `localhost`, `invalid`, `test` ditolak; harus berbeda dari `WINGS_FQDN` | `APP_URL` Panel, route tunnel, `remote` Wings pada mode `public` |
| `WINGS_FQDN` | kosong | ya | sama seperti di atas | route tunnel, FQDN node di Panel |
| `ADMIN_EMAIL` | kosong | ya | alamat email nyata; domain `example.*` ditolak | `APP_SERVICE_AUTHOR` Panel |
| `APP_TIMEZONE` | `UTC` | tidak | nama zona IANA yang ada di `/usr/share/zoneinfo` (mis. `Asia/Jakarta`) | zona waktu Panel |
| `PTERO_ACCEPT_BETA` | `no` | selama Panel pre-release | harus `yes` bila `PANEL_VERSION` memuat `-alpha`, `-beta`, atau `-rc` | gerbang kesadaran risiko; tanpanya perintah yang memvalidasi konfigurasi (hampir semuanya) ditolak dengan kode 3 |

### Port lokal dan jaringan

Semua port terikat ke `127.0.0.1`. Ketiga port ini harus berbeda satu sama lain, dan `GAMES_PORT` tidak boleh sama dengan salah satunya.

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `PANEL_BIND_PORT` | `8081` | 1 sampai 65535 | port Panel di loopback; origin route Panel |
| `WINGS_API_PORT` | `443` | 1 sampai 65535 | port Wings di loopback; origin route Wings. Harus sama dengan **Daemon Port** node, karena Panel menulis `api.port` dari kolom itu dan menimpanya setiap node disimpan. Dengan `WINGS_MODE=container`: port yang dipublikasikan container Wings di `127.0.0.1` (tidak boleh 2022) |
| `TUNNEL_METRICS_PORT` | `20241` | 1 sampai 65535 | endpoint kesiapan cloudflared (`tunnel ready`) |
| `PANEL_EDGE_SUBNET` | `172.29.250.0/24` | jaringan IPv4 privat dalam bentuk `basis/prefiks` dengan prefiks `/16` sampai `/29`; preflight menolak yang tumpang tindih dengan jaringan Docker atau rute host | subnet jaringan `edge`; satu-satunya sumber yang dipercaya Panel untuk header `X-Forwarded-*` (`TRUSTED_PROXIES`) |

### Wings

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `WINGS_MODE` | `host` | `host` atau `container` | `host`: biner dan unit systemd di host (jalur upstream; pakai di VPS). `container`: Wings dan egress guard sebagai layanan Compose dari `compose.wings.yml`, untuk mesin tanpa systemd dan Docker Engine (Docker Desktop di WSL2). Container itu memegang socket Docker dan bind mount path host: [Keamanan](security.md#wings-sebagai-container-risiko-tambahan). Preflight menolak mode ini selama layanan Wings native aktif |
| `WINGS_REMOTE_MODE` | `public` | `public` atau `internal` | `public`: `remote` = `https://PANEL_FQDN` (sesuai dokumentasi upstream). `internal`: `http://127.0.0.1:PANEL_BIND_PORT` tanpa melewati Cloudflare (mode container: `http://panel:80` di jaringan Compose) |
| `WINGS_SFTP_BIND` | `127.0.0.1` | alamat IPv4 | `system.sftp.bind_address` Wings. `0.0.0.0` membuka SFTP; `firewall apply` lalu ikut membuka `2022/tcp` dan `audit` menganggapnya diharapkan. Mode container: alamat host tempat port 2022 dipublikasikan |
| `WINGS_TUNING` | `yes` | `yes` atau `no` | `yes`: menerapkan tuning konservatif ke kunci Wings yang sudah ada (batas PID 512, cek disk tiap 300 detik, batas tulis backup 50 MiB/dtk, tidak restart-loop pada `stop` bersih, batas unggah 100 MB, throttle konsol). Tidak menambah kunci baru |

### Ekstensi dan tema Panel

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `PANEL_EXTENSIONS` | `announcements,custom-buttons,unix` pada contoh; kosong bila tidak ada | daftar id dipisah koma; tiap id harus ada di `extensions/extensions.lock` | ekstensi yang dipasang `setup` dan `ext install`. Kosong = tidak memasang apa pun |
| `PANEL_THEME` | `unix` pada contoh; `classic` bila variabel tidak ada | `classic`, atau id ekstensi tema yang juga ada di `PANEL_EXTENSIONS` | tema aktif. `classic` memanggil `p:theme:reset` |
| `PANEL_EXTENSIONS_ENABLED` | `true` | `true` atau `false` | `PTERODACTYL_EXTENSIONS_ENABLED`. `false` lalu `./ptero up` mematikan semua ekstensi (saklar darurat) |
| `ACTIVITY_PRUNE_DAYS` | `365` | bilangan bulat 1 sampai 3650 | `APP_ACTIVITY_PRUNE_DAYS`: lama log aktivitas staf disimpan (bawaan upstream 90) |

### Server Minecraft (opsional)

Aturan di bawah hanya diperiksa bila `GAMES_ENABLED=yes`, kecuali dua yang pertama.

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `GAMES_ENABLED` | `no` | `yes` atau `no` | menyalakan profil `games` (mc-router) dan impor egg |
| `GAME_NET_SUBNET` | `172.18.0.0/16` | daftar IP atau jaringan; praktisnya satu CIDR; preflight menolak yang tumpang tindih dengan jaringan lain | harus sama dengan `docker.network.interfaces.v4.subnet` Wings. Dipakai egress guard; bila config Wings sudah ada, subnet dari sana yang dipakai dan perbedaannya diperingatkan. `wings configure` menulis nilai ini ke config |
| `GAMES_DOMAIN` | kosong | nama host publik valid; tidak sama dengan `PANEL_FQDN` atau `WINGS_FQDN`, dan keduanya bukan subdomain dari `GAMES_DOMAIN` (pakai nama khusus seperti `mc.contoh.com`) | server menjadi `<nama>.GAMES_DOMAIN` |
| `GAMES_PORT` | `25565` | 1 sampai 65535; di luar rentang backend; tidak sama dengan port lokal lain | port publik mc-router (satu-satunya port game yang dibuka di firewall) |
| `GAMES_BACKEND_FIRST` / `GAMES_BACKEND_LAST` | `25600` / `25699` | 1024 sampai 65535, `FIRST ≤ LAST`, selisih kurang dari 1000 | rentang alokasi `127.0.0.1` untuk server game; tidak pernah dibuka di firewall |
| `GAMES_NODE_ID` | `1` | bilangan bulat | id node tempat `game create` membuat server |
| `GAMES_CONN_RATE` | `10` | 1 sampai 1000 | koneksi baru per detik yang diterima router (`CONNECTION_RATE_LIMIT`) |

### Firewall

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `FIREWALL_SSH_PORTS` | kosong (deteksi otomatis) | daftar port dipisah koma | menggantikan deteksi dari `sshd -T`, sshd yang mendengar, dan sesi SSH Anda |
| `FIREWALL_SSH_ALLOW_CIDRS` | kosong | daftar IP atau jaringan; harus memuat alamat sesi SSH Anda saat `apply` | SSH hanya dari alamat itu |
| `FIREWALL_SSH_LIMIT` | `no` | `yes` atau `no` | `yes`: `ufw limit` (membatasi laju koneksi SSH baru) |
| `FIREWALL_GAME_ALLOW_CIDRS` | kosong | daftar IP atau jaringan | membatasi port game ke alamat itu (komunitas tertutup) |
| `FIREWALL_ROLLBACK_SECONDS` | `300` | `0`, atau 60 sampai 3600 | lama dead-man switch. `0` = tanpa jaring pengaman; `apply` pada host tanpa `systemd-run` menolak kecuali ini `0` |

### Batas resource dan ambang

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `DB_MEM_LIMIT` | `1g` | format memori Docker | `mem_limit` MariaDB |
| `PANEL_MEM_LIMIT` | `1g` | format memori Docker | `mem_limit` Panel |
| `DB_BUFFER_POOL` | `256M` | format ukuran MariaDB | `innodb_buffer_pool_size` |
| `MIN_FREE_DISK_GB` | `10` | bilangan bulat | ambang preflight untuk disk bebas pada direktori data Docker dan repositori |

Tidak ada validasi nilai untuk `DB_MEM_LIMIT`, `PANEL_MEM_LIMIT`, dan `DB_BUFFER_POOL` selain set karakter berkas; nilai yang salah baru ketahuan saat Docker menolaknya.

### Backup

| Variabel | Bawaan | Aturan validasi | Efek |
|---|---|---|---|
| `BACKUP_AGE_RECIPIENT` | kosong | kunci publik `age1...` (huruf kecil dan angka, minimal 50 karakter setelah `age1`) | bila diisi, tiap backup menjadi satu berkas `.tar.age`. Memerlukan paket `age` |

## `config/versions.env`: versi yang dipatok

Berkas ini dilacak Git dan diubah dengan sengaja, lalu diikuti `./ptero update`. Semua image wajib memuat `@sha256:`; tag `:latest` dan image tanpa digest ditolak.

| Variabel | Isi | Dipakai oleh |
|---|---|---|
| `PANEL_VERSION` | tag rilis Panel (`v2.0.0-beta.2`) | pemeriksaan beta, MANIFEST backup, tampilan `status` |
| `PANEL_IMAGE` | `ghcr.io/pterodactyl/panel@sha256:...` | `compose.yml`; `restore` membandingkannya dengan image di backup |
| `MARIADB_IMAGE`, `REDIS_IMAGE`, `CLOUDFLARED_IMAGE` | image dengan digest | `compose.yml` |
| `UTILITY_IMAGE` | `alpine` dengan digest | pembantu sekali pakai: tar volume, pemeriksaan berkas, probe port game |
| `MCROUTER_IMAGE` | `itzg/mc-router` dengan digest | profil `games` |
| `INSTALLER_IMAGE` | `python:3.12-slim-bookworm` dengan digest | kontainer instalasi egg modpack |
| `WINGS_VERSION` | `vX.Y.Z` | unduhan Wings; harus cocok dengan pola `^v[0-9]+\.[0-9]+\.[0-9]+$` |
| `WINGS_SHA256_AMD64`, `WINGS_SHA256_ARM64` | 64 karakter heksadesimal | verifikasi unduhan Wings; biner yang tidak cocok tidak dipasang |
| `WINGS_IMAGE` | `ghcr.io/pterodactyl/wings@sha256:...` | `compose.wings.yml` (mode container); harus berdigest (indeks multi-arsitektur) dan rilisnya sama dengan `WINGS_VERSION` |

Prosedur menaikkan versi (mengambil digest, menghitung sha256, menguji): [Pengembangan](development.md#menaikkan-versi).

## `secrets/`: rahasia

Direktori `secrets/` bermode 700 dan tidak dilacak Git. Semua berkas bermode 600 (atau 400). Rahasia tidak pernah muncul di command line, riwayat shell, atau keluaran log; `diagnose` dan `wings logs` menyamarkannya.

| Berkas | Dibuat oleh | Aturan | Fungsi |
|---|---|---|---|
| `db_password` | `init` | 24 karakter atau lebih, hanya huruf dan angka, bukan nilai lemah yang dikenal | kata sandi pengguna MariaDB `pterodactyl` |
| `redis_password` | `init` | sama | `requirepass` Redis |
| `tunnel_token` | `tunnel set-token` | base64 JSON berisi kunci `a`, `t`, `s` | token konektor cloudflared. Kosong = Panel berjalan tanpa tunnel |
| `panel_api_key` | `key set panel` | `ptla_` diikuti 20 karakter huruf atau angka atau lebih | kunci Application API untuk `games` dan `game create` |
| `panel_client_key` | `key set client` | `ptlc_` diikuti 20 karakter atau lebih | kunci Client API untuk memverifikasi `launch.args` setelah install |
| `curseforge_api_key` | `key set curseforge` | 20 karakter atau lebih dari `A-Za-z0-9$./_-` | sumber CurseForge pada egg |

Seluruh isi `secrets/` ikut `./ptero backup`.

## Berkas dan direktori yang dibuat

| Lokasi | Isi | Dilacak Git |
|---|---|---|
| `config/deploy.env` | konfigurasi Anda | tidak |
| `config/wings-config.restored.yml` | config Wings dari backup, dibuat oleh `restore-config` (mode 600) | tidak |
| `secrets/` | lihat tabel di atas | tidak |
| `backups/` | direktori `<waktu>-<label>/` atau berkas `.tar.age`; `firewall-before-<waktu>.txt` | tidak |
| `runtime/mc-router/routes.json` | tabel nama host ke port untuk mc-router (bukan rahasia) | tidak |
| `/usr/local/bin/wings`, `wings.prev` | biner Wings dan salinan sebelumnya untuk rollback | di luar repositori |
| `/etc/pterodactyl/config.yml` (mode 600), `config.yml.bak-<waktu>` | konfigurasi Wings dan salinan sebelumnya | di luar repositori |
| `/etc/systemd/system/wings.service` | unit Wings | di luar repositori |
| `/etc/systemd/system/ptero-egress-guard.service` | pasang ulang egress guard setiap boot | di luar repositori |
| `/etc/systemd/system/ptero-games-sync.service`, `.timer` | sinkronisasi nama host setiap 2 menit | di luar repositori |
| unit sementara `ptero-firewall-rollback` | dead-man switch, dibuat `systemd-run`, hilang saat dikonfirmasi atau habis | di luar repositori |
| `/var/lib/pterodactyl` | data Wings dan server game | di luar repositori; tidak ikut `./ptero backup` |

## Volume Docker

Nama volume berawalan nama project Compose (`pterodactyl_` secara bawaan).

| Volume | Isi |
|---|---|
| `db_data` | basis data MariaDB |
| `redis_data` | AOF Redis |
| `panel_var` | `/app/var/.env` berisi **`APP_KEY`** dan `HASHIDS_SALT`. Tanpa `APP_KEY` yang asli, data terenkripsi tidak terbaca |
| `panel_nginx`, `panel_logs` | konfigurasi nginx dan log Panel |
| `panel_extensions`, `panel_extension_assets` | paket ekstensi dan aset yang dipublikasikan |

## Variabel lingkungan

Variabel ini diset di shell saat menjalankan `./ptero`, bukan di `deploy.env`.

| Variabel | Bawaan | Efek |
|---|---|---|
| `PTERO_PROJECT` | `pterodactyl` | nama project Compose dan awalan volume. **Mengubahnya setelah instalasi membuat `./ptero` mencari volume dengan nama lain, sehingga data tampak kosong.** Pakai hanya untuk instalasi paralel yang terpisah |
| `PTERO_PREFLIGHT_SKIP` | kosong | `net` melewati pemeriksaan koneksi keluar ke `ghcr.io` dan tepi Cloudflare |
| `TMPDIR` | `/tmp` | lokasi direktori sementara privat milik satu eksekusi (dihapus saat keluar) |

Variabel berikut hanya untuk test dan tidak boleh diset di produksi. `PTERO_TEST_MODE=1` khususnya melewati pemeriksaan root.

| Variabel | Dipakai test untuk |
|---|---|
| `PTERO_TEST_MODE` | menjalankan perintah yang butuh root tanpa root |
| `PTERO_OS_RELEASE` | menggantikan `/etc/os-release` |
| `PTERO_WINGS_BIN`, `PTERO_WINGS_ETC`, `PTERO_SYSTEMD_DIR` | mengarahkan pemasangan Wings dan unit ke direktori sementara |
| `PTERO_SS` | menggantikan perintah `ss` |

## Kode keluar

| Kode | Arti |
|---|---|
| `0` | berhasil |
| `1` | gagal |
| `2` | pemakaian salah |
| `3` | preflight atau konfigurasi tidak valid |
| `4` | ditolak demi keamanan (keadaan berisiko, atau konfirmasi ditolak atau tidak ada terminal) |

Opsi global `--yes` (atau `-y`) menjawab semua konfirmasi, termasuk yang meminta frasa (`RESTORE`), jadi pakai dengan sadar. Tanpa terminal, perintah yang butuh konfirmasi gagal dengan kode 4 kecuali `--yes` diberikan.

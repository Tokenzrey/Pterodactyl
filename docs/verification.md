# Verifikasi: apa yang terbukti, apa yang tidak

> **Jenis:** Referensi · **Untuk:** peninjau, pemelihara, dan operator yang menilai seberapa jauh bisa mempercayai repositori ini · **Tanggal:** 2026-10-20 (uji lanjutan; uji awal 2026-10-19)

Halaman ini mencatat setiap pengujian: apa yang dijalankan, pada apa, hasilnya, dan apa yang belum pernah dijalankan. Ringkasnya: logika dan urutan diuji otomatis dengan tiruan (618 pemeriksaan shell dan 45 test unit Python, semuanya lulus); Panel, ekstensi, router game, installer, Wings, ufw, dead-man switch, dan egress guard dijalankan pada komponen asli di mesin uji; **belum ada pemasangan di VPS Linux nyata, belum ada akun Cloudflare nyata, dan belum ada server Minecraft nyata yang dijalankan lewat Wings** (Wings sebagai container menjalankan container game uji di Docker Desktop; lihat bagian di bawah).

## Cara membaca halaman ini

Tiga label dipakai konsisten di seluruh dokumentasi:

| Label | Arti |
|---|---|
| **Nyata** | Dijalankan pada komponen asli (image atau biner yang dipatok) di mesin uji |
| **Otomatis** | Dicakup `bash tests/run.sh` dengan tiruan (`docker`, `curl`, `systemctl`, `ufw`, `iptables`, Panel palsu) |
| **Belum diuji** | Dirancang dari dokumentasi upstream atau bacaan kode, belum dijalankan |

## Lingkungan dan metode

| Hal | Rincian |
|---|---|
| Mesin uji | Ubuntu 24.04 (WSL2) di Windows 11, Docker 29.8.2 (Docker Desktop), Compose v5.6.0, Python 3.11 |
| Isolasi | Pemeriksaan "nyata" memakai project Compose terpisah (`ptero-verify`), port dan subnet terpisah, lalu dihapus. Stack lama (`pterodactyl_*`, `pterodactyl_nw`) tidak disentuh |
| ufw, iptables, systemd | Dijalankan di container Ubuntu uji (systemd sebagai PID 1) dan network namespace uji, bukan di host. `apt` dan `apk` dari container diblokir proxy TLS di jaringan uji, jadi paket `.deb` ufw dan iptables diunduh di host lalu dipasang offline |
| Wings | Biner resmi 1.13.4 di container systemd uji. Panel di host menjangkaunya lewat forwarder TCP yang menggantikan tunnel |
| Image installer | Dibangun lokal dari base Python (tag `ptero-installer-test:py`), bukan image digest yang di-pull. Alurnya sama, tetapi bukan artefak yang sama persis |
| Cloudflare | Tidak digunakan. Tidak ada akun, token, atau domain nyata yang disentuh |
| CurseForge | Tidak ada kunci nyata yang dipakai (kunci milik orang lain sengaja tidak dipakai) |

## Fakta upstream (diperiksa ulang, bukan disalin dari catatan lokal)

| Fakta | Sumber atau cara |
|---|---|
| Panel 2.0 masih beta (`v2.0.0-beta.2`, *pre-release*); stabil terbaru `v1.15.1`; catatan beta.1: "keep production panels on 1.x for now" | [halaman rilis `pterodactyl/panel`](https://github.com/pterodactyl/panel/releases) |
| Wings `v1.13.4` stabil; docs: 1.13.2 sampai 1.13.4 diuji dengan Panel 2.0; sha256 aset dari API rilis GitHub, **amd64 diunduh dan di-hash ulang: cocok** | [halaman rilis `pterodactyl/wings`](https://github.com/pterodactyl/wings/releases), GitHub API, unduhan nyata |
| Digest `panel:v2.0.0-beta.2`, `mariadb:11.4`, `redis:7.4-alpine`, `cloudflared:2026.10.1`, `alpine:3.20`, `itzg/mc-router:1.47.2` (4 Okt), `python:3.12-slim-bookworm` (image installer) | API registry ghcr.io dan Docker Hub |
| Alur Docker Panel 2.0 (migrate dan seed sekali, `p:user:make`), update (`migrate --seed`, seeder menimpa egg bawaan), persyaratan Wings, kunci config Wings | `docs.pterodactyl.io/v2` (panel/docker, panel/updating, wings/installing, wings/configuration) |
| Route tunnel memerlukan skema di Service URL; Access: deny bawaan, hindari Bypass di `/admin`; Spectrum: berbayar, TCP/UDP kustom = Enterprise | dokumentasi Cloudflare |
| Flag mc-router: `PORT`, `ROUTES_CONFIG`, `ROUTES_CONFIG_WATCH`, `CONNECTION_RATE_LIMIT`; format JSON `mappings`; reload dengan SIGHUP atau watch; image berjalan non-root | README [`itzg/mc-router`](https://github.com/itzg/mc-router) dan percobaan nyata |
| **Panel 2.0 beta.2 dari kode di image:** egg diimpor lewat aksi `ImportEgg`/`UpdateEggFromImport` (tidak ada perintah artisan); `author` egg harus alamat email; `relationships` berada di dalam `attributes`; izin kunci Application = kolom `r_servers`, `r_nodes`, `r_allocations`, `r_users`, `r_eggs` | membaca source di image, dikonfirmasi saat dijalankan |
| Mojang: Java yang dibutuhkan per versi (`1.7.10` sampai `1.16.5` → 8, `1.18` sampai `1.20.1` → 17, `1.20.5` dan `1.21.1` → 21, **`26.1` sampai `26.3` → 25**) | `piston-meta.mojang.com` (versi Minecraft terbaru saat ini `26.3`) |
| Fabric Meta (`.../server/jar`), installer Forge dan NeoForge di maven, Quilt installer, Adoptium (Java 8) semuanya ada | permintaan HEAD nyata |
| "Modpack Installer for Blueprint" (BuiltByBit) adalah ekstensi berbayar, closed-source, untuk Blueprint | halaman BuiltByBit |

## Test otomatis

Perintah: `bash tests/run.sh`. Hasil 2026-10-21: **618 pemeriksaan shell** (termasuk `t_games.sh` dan `t_installer.sh` yang juga menjalankan **45 test unit Python**: 17 + 28), semuanya lulus, `ALL TEST FILES PASSED`.

| File | Pemeriksaan | Cakupan |
|---|---|---|
| `t_config.sh` | 64 | init idempoten; validasi (placeholder, skema, host, email, beta, port, subnet, zona waktu, `WINGS_MODE`, `WINGS_IMAGE`); `deploy.env` tidak pernah dieksekusi; image `:latest` ditolak; rahasia lemah atau longgar; token tunnel |
| `t_stack.sh` | 57 | setup instalasi baru, ulang, dan keadaan berbahaya (APP_KEY hilang, migrasi tertunda); kegagalan migrate, pull, dan docker; subnet dan port bentrok (termasuk `GAME_NET_SUBNET`, `pterodactyl_nw`, dan bridge `pterodactyl0`); status, verify, update (urutan, abort bila backup gagal) |
| `t_backup.sh` | 53 | isi dan izin backup, checksum, dump gagal atau terpotong, restore (semua penolakan sebelum perubahan, jalur aman, impor gagal), restore-config, backup terenkripsi (age palsu) |
| `t_wings.sh` | 154 | mode container (install tanpa dan dengan config, config di volume mode 600 dan tidak di pohon repositori, label volume, `up` memulihkan Wings, `configure` dan backup config, `update`, `logs`, `status`, penolakan saat Wings native aktif, perintah egress host ditolak, `diagnose` tanpa token), `--container` di `wings_config.py`; pemeriksaan dan penambalan config Wings (hanya baris yang dimaksud berubah, termasuk SFTP loopback, `bind_address` dihilangkan = semua antarmuka, subnet, gateway, dan `enable_icc` jaringan game, JSON dari Panel dibaca, token tidak dicetak), pemasangan biner dengan sha256, `install --config`, configure, update (pin tidak cocok ditolak, rollback biner lama) |
| `t_firewall.sh` | 64 | rencana, urutan aturan (SSH sebelum enable), dead-man switch, semua jalur penolakan lock-out (SSH tak terdeteksi, port sesi di luar daftar, allow-list tanpa alamat Anda), kegagalan ufw, aturan egress (idempoten, subnet Wings menang), audit listener dan container |
| `t_games_cli.sh` | 67 | validasi konfigurasi game, penyimpanan kunci (jenis kunci salah ditolak, tidak pernah di-echo), `games sync/list/status/dns/timer` terhadap mock Panel, reload router hanya bila tabel berubah, `game create` (penolakan), `egg build/install` (kunci tidak di command line) |
| `t_games.sh` | 5 (+17 unit) | `games.py` terhadap mock Panel stateful: hanya server Minecraft berloopback yang dirutekan, tabrakan nama menolak dan tidak menulis, Panel mati atau kunci salah tidak menghapus tabel, rencana tidak membuat apa pun, apply membuat alokasi, server, dan rute, verifikasi install lewat `launch.args`, penolakan; berkas egg identik dengan hasil build sumbernya |
| `t_installer.sh` | 1 (+28 unit) | installer modpack terhadap mock Modrinth, CurseForge, dan CDN: hash salah membatalkan, path berbahaya, host unduhan di luar allow-list, client-only dilewati, reinstall menjaga dunia, config, dan mod milik pemilik, probe CurseForge hanya metadata, kunci API tidak dikirim ke host unduhan |
| `t_ext.sh` | 54 | `extensions.lock` (format, pin tag rilis, paket lokal cocok dengan sha256 dan manifestnya), `ext vet` (bersih versus mencurigakan), aturan konfigurasi, install dan reconcile terhadap Panel palsu: backup lebih dulu, idempoten, drift versi memasang ulang satu paket, byte atau versi yang beda, backup gagal, dan install gagal ditolak, saklar darurat, tema kembali ke classic tanpa menghapus apa pun, `setup` menerapkan keadaan yang diinginkan dan tidak gagal bila satu ekstensi gagal |
| `t_docs.sh` | 10 | tautan relatif dan anchor di `README.md` dan `docs/*.md` ada, `docs/README.md` mengindeks semua halaman, bagian yang dirujuk pesan di `lib/` masih ada, dan pemeriksa benar-benar menangkap tautan rusak (diuji dengan checkout palsu) |
| `t_static.sh` | 89 | pengaman suite (berhenti bila tiruan tidak dipakai, bila sandbox gagal dibuat, `ptero` menolak docker asli; tiruan tanpa bit eksekusi tetap bekerja); **`compose.wings.yml` dirender nyata**: socket dan bind host hanya di `wings`, path identik, digest, port loopback, satu capability tambahan; `bash -n`; **`docker compose config` nyata**: semua port `127.0.0.1`, digest, `no-new-privileges`, tanpa socket Docker, satu-satunya bind mount adalah tabel router read-only, `backend` internal, hanya cloudflared dan mc-router berjaringan host (read-only, `cap_drop ALL`); pemindaian rahasia; tanpa `curl \| sh`, tanpa penghapusan volume atau backup; redaksi; diagnosa tanpa rahasia; **shellcheck bersih** (bila tersedia) |

## Pemeriksaan pada sistem nyata (di luar test otomatis)

### Stack Panel nyata (image yang dipatok, project `ptero-verify`, dihapus setelahnya)

| Diperiksa | Hasil |
|---|---|
| `./ptero setup` ujung ke ujung: pull, MariaDB, Redis, `migrate --seed`, Panel, mc-router, `--wait` | berhasil; semua `healthy` |
| `setup` kedua | mendeteksi instalasi, **tanpa migrate atau seed, `APP_KEY` identik** |
| `./ptero egg install` ke Panel nyata | pertama kali **gagal** dan menemukan dua bug nyata: (1) Panel mewajibkan `author` berupa email; (2) `docker cp` membuat berkas milik uid lain sehingga berkas berisi kunci tertinggal di container dan retensi kunci gagal diam-diam. Keduanya diperbaiki (author email; berkas dialirkan lewat stdin dan dihapus). Setelah itu: impor, lalu update, 1 egg, variabel kunci tersembunyi (`user_viewable` dan `user_editable` = 0), kontainer install dipatok digest, **kunci CurseForge yang tersimpan tetap ada saat install ulang tanpa kunci**, tidak ada berkas sisa di container |
| Kunci Application API dibuat lewat aksi `CreateApiKey` dengan izin yang didokumentasikan; `./ptero key set panel` menerimanya | bentuk `ptla_...` 48 karakter diterima |
| `games sync` dan `games list` terhadap API Panel **nyata** | berjalan; bentuk respons (`include=allocations`) sesuai asumsi kode |
| `./ptero backup`, hapus user, lalu `./ptero restore --yes` | user kembali; safety backup `pre-restore` dibuat |
| `update --check`, `diagnose` | bersih; kata sandi DB muncul **0 kali** dalam laporan |
| **Satu `./ptero setup` pada Panel baru memasang ekstensi dan tema** (unduhan nyata dari GitHub, sha256 dicocokkan) | `announcements`, `custom-buttons`, `unix` terpasang dan `enabled` menurut `p:extension:list` Panel sendiri; tema `unix` `active` menurut `p:theme:list`; halaman login menyajikan `data-theme="unix"` dan `/assets/extensions/unix/<hash>/theme.css`; direktori ekstensi dimiliki `nginx`; egg modpack diimpor oleh `setup` (games aktif); env `PTERODACTYL_EXTENSIONS_ENABLED`, `APP_ACTIVITY_PRUNE_DAYS`, dan `APP_BACKUP_DRIVER` sampai ke container Panel |
| `./ptero ext install` kedua | semua "already installed and enabled", tidak ada backup tambahan |
| `ext vet` pada tiga paket nyata | tidak ada panggilan PHP yang ditandai (tripwire tidak memberi alarm palsu) |

### Container sekali pakai

| Diperiksa | Hasil |
|---|---|
| Redis dengan flag persis `compose.yml` (user 999, `cap_drop ALL`, read-only, tmpfs) | `PONG`, menolak tanpa kata sandi, **kata sandi tidak ada di `/proc/1/cmdline`** |
| cloudflared | `tunnel ready` membaca `TUNNEL_METRICS`; menolak token tidak valid dengan bersih saat read-only |
| **mc-router** (image dipatok, read-only, `cap_drop ALL`, `no-new-privileges`) dengan klien Minecraft tiruan | nama terpetakan → backend menerima handshake; huruf besar atau kecil tak berpengaruh; sufiks Forge `\0FML\0` tetap diroute; **nama tak dikenal, IP mentah, dan nama kosong → ditutup, backend tidak menerima apa pun**; menambah rute di berkas lalu reload → aktif |
| Installer modpack dengan **jaringan nyata**: Fabric (Modrinth, Minecraft **26.2 → Java 25**), Forge `1.20.1` (Java 17), NeoForge `1.21.1` (Java 21), **Forge `1.12.2` (JRE 8 sementara dari Adoptium)** | keempatnya terpasang dan, dijalankan di image yolks Java yang sesuai, memuat loader dan mod lalu **berhenti di persyaratan EULA** (EULA tidak diterima oleh pengujian) |

### Firewall, ufw, dan dead-man switch (ufw 0.36.2 dan systemd asli di container uji)

| Diperiksa | Hasil |
|---|---|
| `firewall apply` dengan ufw asli: default-deny masuk, SSH terdeteksi dan tetap diizinkan, port router game diizinkan | aturan terpasang; verifikasi pasca-apply lewat aturan `ufw-user-input` di iptables. `ufw status` tidak dipakai di container: `ufw enable` mencetak `ERROR: problem running sysctl` dan status tidak terbaca di dalam container |
| `firewall apply` dengan dead-man aktif tetapi tanpa `systemd-run` | **ditolak** (exit 4) sebelum mengubah apa pun. Versi sebelumnya salah cabang dan tidak menolak; sudah diperbaiki |
| Dead-man switch pada systemd asli | ufw mati otomatis saat waktu habis bila tidak dikonfirmasi (uji memakai 60 detik; bawaan `FIREWALL_ROLLBACK_SECONDS` 300); `firewall confirm` membatalkan timer |
| Egress guard (`DOCKER-USER` + INPUT) di network namespace dengan bridge dan trafik nyata | trafik dari container game ke rentang privat dan metadata diblokir; koneksi keluar biasa dan balasan koneksi yang dimulai dari host diizinkan. Pelajaran: `DOCKER-USER` hanya memengaruhi trafik yang diteruskan, jadi uji dari host saja memberi hasil palsu; uji sekarang lewat jalur container → bridge |

### Wings resmi 1.13.4 di container systemd uji (`ptero-wings-host`; Panel nyata, forwarder TCP sebagai pengganti tunnel)

| Diperiksa | Hasil |
|---|---|
| `wings install`: biner amd64 dengan sha256 yang dipatok, unit systemd | cocok; unit terpasang; service aktif; `wings status` menjawab |
| `wings configure` dengan JSON konfigurasi node nyata dari Panel | config tertulis: bind SFTP, jaringan Docker (`enable_icc: false`, subnet dan gateway game), `remote` sesuai; token tidak dicetak |
| Koneksi dua arah Panel ↔ Wings | node online di Panel; Wings menjawab pemanggilan dari Panel |
| Install server Forge 1.20.1 (modpack) lewat Wings | **selesai**: `launch.args` ada, direktori JRE sementara `.ptero-jre` dihapus. Percobaan pertama gagal `No space left on device`: `tmpfs_size` 100 MB dari tuning terlalu kecil untuk JRE. Tuning tmpfs dihapus; JRE sekarang di folder server lalu dihapus setelah install |
| Wings 1.13.4 menandai install `completed` walau skrip keluar non-nol (terlihat: exit 127 dan traceback) | `game create` memeriksa `launch.args` lewat Client API (`ptlc_`, `./ptero key set client`) dan mendapat 200. Tanpa kunci client, hanya peringatan "not verified" |

### Wings sebagai container di Docker Desktop (daemon nyata)

Project Compose terpisah `ptero-wtest` (Panel segar tanpa tunnel, port 18081 dan 18443, subnet edge `172.29.251.0/24`), Wings 1.13.4 dari `WINGS_IMAGE`, Docker Desktop 29.9.1 pada WSL2, 2026-10-21. Keadaan daemon (container, volume, jaringan, dan aturan iptables di VM) dicatat sebelum uji dan dibandingkan sesudahnya.

| Diperiksa | Hasil |
|---|---|
| Penyebab kegagalan `/etc/machine-id` yang lama | dua container game sisa uji lama punya bind `/run/wings/machine-id/<uuid>` ke `/etc/machine-id`, dan path sumber itu kini berupa **direktori**. Percobaan terpisah dengan container berisi `docker.sock`: dengan mount identitas, berkas yang ditulis container terbaca oleh container saudara (lewat `--mount` maupun `-v`); tanpa mount identitas, container saudara melihat direktori |
| Preflight dan `wings install` terhadap layanan Wings native yang **nyata** (aktif) | `[FAIL]` dengan penjelasan, `wings install` kode keluar 4, tidak ada container yang berubah. Dengan layanan itu disembunyikan (shim hanya untuk uji), preflight hijau |
| `setup`, lalu `wings install --config` dari `p:node:configuration` | config ditambal dan masuk volume `ptero-wtest_wings_etc` (mode 600, berlabel Compose, tanpa salinan di pohon repositori); `wings` berstatus `running`, `egress-guard` `healthy`; API menjawab 401 |
| Panel ke Wings, dan Wings ke Panel | dari container Panel, `DaemonConnection::forNode(...)->request('get', '/api/system')` menjawab HTTP 200 (`version 1.13.4`). Wings memuat daftar server dari Panel lewat `http://panel:80` |
| Jalur tunnel | dari container berjaringan host (namespace daemon, tempat `cloudflared` berjalan), `http://127.0.0.1:18443/api/system` menjawab 401 |
| Server uji (egg Vanilla, `skip_scripts`, image `yolks:java_17`, startup `sleep 3600`) dibuat lewat API Panel dan dijalankan lewat Client API | container game berjalan; `/etc/machine-id` berupa **berkas** 33 byte berisi ID 32 heksadesimal, sama dengan berkas di `/run/wings/machine-id/<uuid>`; jaringan `pterodactyl_nw` (172.22.0.2); alokasi hanya di `127.0.0.1:25570` (tcp dan udp); data di `/var/lib/pterodactyl/volumes/<uuid>` milik uid 988. Percobaan pertama memakai startup `sh -c '...'` dan keluar langsung: entrypoint `yolks` mengevaluasi string startup tanpa kutip, bukan masalah Wings |
| Egress guard | aturan `DOCKER-USER` (lima drop, satu `RETURN` conntrack di atasnya) dan `INPUT` terpasang. Dari dalam container game, `192.168.65.7:53`, `192.168.65.254:80`, `169.254.169.254:80`, `10.0.0.1:80`, dan gateway jaringan game **diblokir**; `1.1.1.1:443` **terjangkau** |
| Siklus hidup | `./ptero down`: container game tetap berjalan dan volume config tetap; `./ptero up`: Wings dan guard kembali dari config dan Wings mencatat `detected server is running, re-attaching to process`; `wings update`; `wings logs`; `backup` memuat `wings/config.yml`; `diagnose` tidak memuat token maupun token id; menghapus server lewat API menghapus container dan datanya |
| Pembersihan | container, volume, jaringan, dan aturan iptables daemon **identik** dengan keadaan sebelum uji |

Batas: server uji bukan server Minecraft dan tidak menjalankan modpack. Tidak diuji: WebSocket konsol, route Cloudflare dengan domain nyata, restart Docker Desktop. Layanan Wings native di mesin uji disembunyikan dengan shim selama uji, dan port SFTP uji memakai `127.0.0.2` karena layanan itu memegang `127.0.0.1:2022` (temuan nyata: Docker Desktop menolak mempublikasikan 2022, `ports are not available`).

### mc-router dengan jaringan host dan handshake Minecraft nyata

| Diperiksa | Hasil |
|---|---|
| Login start asli dengan nama yang terdaftar | diteruskan ke backend |
| Nama tak dikenal dan IP mentah | log `Unable to find registered backend`; koneksi ditutup; backend tidak menerima apa pun |
| `games sync` dari data Panel nyata | rute hanya untuk server Minecraft yang punya alokasi 127.0.0.1 dan tidak suspended (egg bernama "minecraft") |
| `preflight` jaringan | menolak subnet game yang tumpang tindih dengan jaringan lain (uji dengan 172.18.0.0/16), jaringan `pterodactyl_nw` dengan subnet berbeda, dan nama bridge `pterodactyl0` yang dipakai jaringan lain |

## Yang gagal atau belum lolos

Dicatat, tidak disembunyikan.

| Diperiksa | Hasil |
|---|---|
| Container game yang dibuat Wings dijalankan di Wings yang ada di dalam container (Docker Desktop), uji awal | **gagal**: bind mount `/etc/machine-id` dari Wings ke container game gagal (`not a directory`). Server uji "Survival" dan "Kampung" berhenti di status install; container game tidak pernah jalan. Penyebabnya mount identitas `/run/wings` yang tidak ada pada susunan uji: daemon membuat direktori di path sumber. **Diperbaiki dan dibuktikan** dengan `compose.wings.yml` ([bagian di atas](#wings-sebagai-container-di-docker-desktop-daemon-nyata)) |
| apt dan apk dari dalam container | diblokir proxy TLS di jaringan uji; paket ufw `.deb` diunduh di host lalu dipasang offline |
| Image installer di uji | dibangun lokal (`ptero-installer-test:py`) dari base Python, bukan image digest yang di-pull |
| Opsi `game create --label` | **cacat yang diketahui, ditemukan saat menulis dokumentasi:** hanya memengaruhi alamat yang ditampilkan di rencana dan pemeriksaan bentrok; rute yang ditulis selalu memakai slug nama server. Lihat [Referensi perintah](commands.md#opsi-game-create) |

## Temuan yang mengubah kode

Pengujian nyata menemukan masalah yang tidak tertangkap test otomatis. Daftar ini ada supaya Anda tahu jenis kegagalan yang pernah terjadi, dan karena tiap baris kini punya perlindungan di kode atau test.

| Temuan | Perbaikan |
|---|---|
| Deteksi subnet bentrok membaca stdin dari heredoc Python sehingga tidak pernah mendeteksi | program lewat `-c`, kandidat lewat stdin; test ditambahkan |
| Egg gagal diimpor: `author` harus email; `docker cp` meninggalkan berkas berisi kunci | author email; berkas dialirkan lewat stdin dan dihapus |
| `firewall apply` salah cabang dan tidak menolak tanpa `systemd-run` | ditulis ulang; menolak dengan kode 4 kecuali `FIREWALL_ROLLBACK_SECONDS=0` |
| Pengujian egress dari host memberi hasil palsu | uji lewat jalur container → bridge di network namespace |
| `game create` menganggap install selesai terlalu dini (status `null` sebelum Wings mulai) | menunggu `container.installed`, dengan batas waktu dan deteksi Wings tidak terhubung |
| Wings 1.13.4 menandai install selesai walau skrip gagal | verifikasi `launch.args` lewat Client API |
| Daftar rute kosong karena `features` egg tidak dikembalikan API | server Minecraft dikenali dari nama egg |
| `games status` melaporkan "NOT listening" pada Docker Desktop | probe port dari container berjaringan host |
| Install gagal `No space left on device` | tmpfs dihapus dari tuning; JRE sementara di folder server |
| Wings gagal start karena jaringan lama (subnet berbeda, nama bridge `pterodactyl0`, `Pool overlaps`) | pemeriksaan preflight dan pesan yang menyebut perbaikannya |
| Opsi `--loader` tidak ada | ditambahkan, harus cocok dengan pack |
| `bash tests/run.sh` di checkout WSL memakai `docker`, `curl`, dan `systemctl` **asli** (tiruan tidak punya bit eksekusi karena Git mencatatnya `100644`) dan menghentikan serta menghapus container stack yang hidup (volume selamat) | test menyalin tiruan dan memberinya bit eksekusi sendiri; `assert_fakes_first` berhenti (99) bila alat tidak resolve ke tiruan; `DOCKER_HOST` ke socket yang tidak ada; `ptero` menolak `PTERO_TEST_MODE=1` dengan docker asli; test regresi di `t_static.sh` |
| `sandbox()` yang gagal membuat direktori menjadikan salinan repositori `/root` | berhenti (99) bila direktori tidak terbentuk; direktori dasar diingat antar sandbox |
| Dua `restore` dalam detik yang sama bertabrakan di nama `pre-restore` (test flaky; produk gagal aman, tidak ada yang berubah) | `sleep 1` sebelum restore terenkripsi, seperti restore sebelumnya |
| Volume `wings_etc` dibuat tanpa label Compose, sehingga Compose memperingatkan di setiap start | dibuat dengan label proyek dan volume; ada test |
| Wings container gagal mempublikasikan SFTP 2022 selama Wings native memegangnya | preflight dan `wings install` menolak selama layanan native aktif |

## Belum diverifikasi

| Hal | Mengapa | Risiko |
|---|---|---|
| Pemasangan di VPS Linux nyata (ufw, iptables, systemd, `network_mode: host` di host Linux) | ufw, iptables, dan dead-man sudah jalan di container uji (Docker Desktop), tetapi aturan belum pernah diterapkan di host VPS | **sedang**: buka sesi SSH cadangan sebelum `firewall apply` pertama. Setelah apply, periksa `systemctl list-timers` dan `./ptero audit` |
| Wings systemd di host Linux menjalankan container game (start, konsol, jaringan Docker) | berhasil di Docker Desktop dengan Wings sebagai container (bagian di atas); Wings systemd di host Linux belum pernah menjalankan server | **sedang** di VPS: ini yang diuji pertama, dengan satu server kecil yang bisa dihapus |
| Mode container: route Cloudflare dengan domain nyata, WebSocket konsol, restart Docker Desktop (aturan guard dipasang lagi?), modpack Minecraft nyata | butuh akun, browser, atau modpack nyata | sedang |
| mc-router di host Linux dengan firewall nyata dan port publik | handshake sudah diuji, tetapi tidak dengan firewall nyata. Di Docker Desktop port "host" tidak terlihat dari WSL, sehingga `games status` melaporkan "NOT listening" pada uji; log router menunjukkan mendengar | rendah-sedang |
| `game create` sampai server berjalan | pembuatan server, install lewat Wings, dan verifikasi `launch.args` sudah diuji (Kampung); start container belum | sedang |
| CurseForge dengan kunci nyata | tidak ada kunci CurseForge pada sesi ini (dan kunci milik orang lain tidak dipakai) | sedang: alur diuji dengan mock dan kode berbagi logika dengan alat lama yang pernah berhasil pada pack nyata |
| Quilt dan pack Forge atau NeoForge berukuran besar | tidak ada pack Quilt uji | rendah-sedang |
| Cloudflare: tunnel, route, DNS wildcard, Access, WAF | butuh akun Anda | sedang |
| Header `X-Forwarded-*` dari host ke port loopback Panel (`TRUSTED_PROXIES`) | NAT Docker host nyata | sedang |
| WebSocket konsol Wings lewat Cloudflare, `WINGS_REMOTE_MODE=internal` untuk konsol | butuh Panel, Wings, dan browser | sedang |
| Efek `enable_icc: false` pada lalu lintas antar-container game | server game belum pernah dijalankan | rendah-sedang |
| Enkripsi `age` nyata; update terhadap versi lebih baru; Debian 12/13 dan Ubuntu 22.04/26.04, arm64 | tidak tersedia | rendah-sedang |
| Prosedur migrasi dari stack lama ([Migrasi](migration.md)) | stack lama tidak disentuh | sedang |
| Rotasi rahasia selain token tunnel ([Keamanan](security.md#respons-insiden-dan-rotasi-rahasia)) | tidak ada prosedur teruji | sedang |
| Panel 1.x | tidak didukung (kontrak env berbeda) | - |

## Daftar periksa untuk VPS Anda

Pengujian di atas tidak menggantikan pemeriksaan pada host Anda sendiri. Setelah [Instalasi lengkap](installation.md), jalankan ini berurutan dan catat hasilnya:

1. `bash tests/run.sh` pada checkout Anda: harus `ALL TEST FILES PASSED`.
2. `./ptero preflight`: tidak ada `[FAIL]`.
3. Dengan sesi SSH cadangan terbuka: `./ptero firewall plan`, `sudo ./ptero firewall apply`, login dari sesi baru, `sudo ./ptero firewall confirm`. Lalu `./ptero audit` harus bersih dan `systemctl list-timers ptero-firewall-rollback.timer` tidak menampilkan timer tertunda.
4. `sudo ./ptero firewall egress install` lalu `./ptero firewall egress status`: semua baris `ok`. Dari dalam container game uji, koneksi ke alamat privat host Anda harus gagal.
5. `./ptero wings status`: versi sama dengan pin dan API menjawab `401`.
6. Buat satu server kecil (misalnya paket Modrinth ringan, `--memory` kecil), tekan Start di Panel, terima EULA, dan sambungkan dengan klien Minecraft lewat `nama.mc.contoh.com`. Ini menutup celah "Wings menjalankan container game".
7. Sambungkan klien dengan IP langsung: harus ditolak.
8. Ambil `./ptero backup`, restore ke mesin cadangan, dan masuk ke Panel di sana.

Laporkan perbedaan antara hasil Anda dan halaman ini; halaman ini diperbarui setiap pengujian baru.

## Pembersihan

Setelah pengujian 2026-10-20, project `ptero-verify` (container, volume, jaringan), container `ptero-sys`, `ptero-wings-host`, `ptero-fw-test`, dua container game uji, image uji `ptero-*-test`, forwarder uji, dan `/var/lib/pterodactyl-verify` dihapus. Stack lama tidak disentuh: container `pterodactyl-*` tetap berhenti seperti sebelumnya, 7 volume `pterodactyl_*` utuh, serta `pterodactyl_nw` dan `koperasi-network` masih ada.

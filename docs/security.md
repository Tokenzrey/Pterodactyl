# Keamanan: model ancaman, kontrol, dan respons insiden

> **Jenis:** Konsep + panduan · **Untuk:** operator dan peninjau keamanan · **Diperbarui:** 2026-10-20 · **Audit independen:** belum ada

Halaman ini menyatakan apa yang dilindungi, dari siapa, dengan kontrol apa, dan apa yang tetap berisiko setelah semua kontrol dipasang. Setiap kontrol diberi status verifikasi yang sama dengan [dokumentasi lain](README.md#konvensi-dokumentasi). Repositori ini belum diaudit pihak ketiga dan tidak melalui uji penetrasi; klaim di sini berdasarkan bacaan kode, test otomatis, dan pemeriksaan pada komponen asli di mesin uji. Rancangan jaringan dan port ada di [Arsitektur](architecture.md).

## Aset yang dilindungi

| Aset | Lokasi | Bila bocor |
|---|---|---|
| `APP_KEY` dan `HASHIDS_SALT` | volume `panel_var`; ikut backup | mendekripsi data terenkripsi Panel: kunci API, token node, rahasia 2FA; memalsukan sesi |
| Kata sandi MariaDB dan Redis | `secrets/db_password`, `redis_password`; ikut backup | akses ke data Panel dan sesi; hanya dapat dijangkau dari jaringan `backend` internal |
| Token tunnel Cloudflare | `secrets/tunnel_token`; ikut backup | pihak lain dapat menjalankan konektor atas tunnel Anda dan menerima lalu lintas yang ditujukan ke origin |
| Token node (konfigurasi Wings) | `/etc/pterodactyl/config.yml` (600) | Panel dan node saling mempercayai lewat token ini; memegangnya berarti dapat memerintah Wings |
| Kunci Application API (`ptla_`) dan Client API (`ptlc_`) | `secrets/panel_api_key`, `panel_client_key` | `ptla_` mengelola server, alokasi, dan pengguna; `ptlc_` membaca berkas server milik akun |
| Kunci CurseForge | `secrets/curseforge_api_key`; variabel egg | kuota dan akun CurseForge Anda disalahgunakan |
| Akses Docker socket | proses Wings (root) | setara root atas host |
| Data game (dunia, mod) | `/var/lib/pterodactyl` | hilang atau dirusak; tidak ikut `./ptero backup` |

## Aktor dan batas kepercayaan

| Aktor | Kemampuan wajar | Dibatasi oleh |
|---|---|---|
| Penyerang dari internet tanpa kredensial | mencapai SSH, port router game, dan HTTPS lewat Cloudflare | firewall default-deny, tidak ada port web terbuka, router menolak IP langsung dan nama tak dikenal, batas laju koneksi router |
| Pemain Minecraft | menyambung ke nama server yang dikenal | router; server game hanya di loopback; `online-mode=true` secara bawaan |
| Penulis mod atau modpack | menjalankan kode bebas di JVM server game | container Wings, egress guard (tidak ke host, LAN, metadata cloud), batas resource. **Tidak** dibatasi dari internet umum |
| Pemilik server Panel (non-admin) | mengubah variabel egg (`MODPACK_SOURCE`, `MODPACK_ID`), mereinstall, menjalankan konsol | sumber `url` menolak alamat privat; egress guard; batasi siapa yang boleh membuat server |
| Administrator Panel | mengelola semua; memasang ekstensi (akses penuh ke Panel); membuat server dengan image dan perintah pilihannya, yang dijalankan Wings sebagai root | **kepercayaan penuh.** Perlakukan akun admin setara akses root ke host; 2FA dan Cloudflare Access di jalur admin |
| Cloudflare | menghentikan TLS; melihat seluruh lalu lintas web (termasuk login Panel) dalam bentuk plaintext | **asumsi kepercayaan** yang melekat pada desain tunnel; tidak bisa dihilangkan tanpa mengganti desain |
| Pengguna lokal di host | membaca berkas yang izinnya terbuka | `secrets/` 700, berkas 600, `umask 077`; root tetap dapat membaca semuanya |

## Kontrol dan status verifikasi

| Kontrol | Implementasi | Status |
|---|---|---|
| Semua port terpublikasi hanya di `127.0.0.1` | `compose.yml` | **Otomatis** (hasil render `docker compose config`); **Nyata** pada stack uji |
| MariaDB dan Redis di jaringan `internal` tanpa rute keluar dan tanpa port | `compose.yml` | **Otomatis** |
| `no-new-privileges` di semua container; `cap_drop ALL` dan rootfs read-only di Redis, cloudflared, dan mc-router | `compose.yml` | **Otomatis**; **Nyata** untuk Redis dan mc-router |
| Image dipatok digest; `:latest` ditolak validasi | `versions.env`, `validate_config` | **Otomatis** |
| Tidak ada Docker socket di container mana pun; satu-satunya bind mount adalah tabel router (read-only) | `compose.yml` | **Otomatis** |
| Batas memori, batas PID, dan rotasi log (10 MB × 3) di tiap container | `compose.yml` | Dijalankan pada stack uji (**Nyata**); efek pembatasan tidak diukur |
| Kata sandi DB dan Redis acak 192-bit; berkas rahasia 600, direktori 700; validasi menolak izin longgar dan nilai lemah | `ptero init`, `check_secrets` | **Otomatis** |
| Kata sandi Redis tidak muncul di argumen proses; kata sandi DB lewat `MYSQL_PWD` di dalam container; token tunnel hanya dari berkas | `compose.yml`, `lib/stack.sh` | **Nyata** untuk Redis (`/proc/1/cmdline`); **Otomatis** untuk sisanya |
| Konfigurasi di-*parse*, bukan di-*source* | `lib/config.sh` | **Otomatis** |
| Wings: `api.host` dan SFTP di loopback, `trusted_proxies` terbatas, config 600 di direktori 700, `enable_icc: false` pada jaringan game | `lib/wings_config.py` | **Otomatis**; **Nyata** (penambalan pada JSON konfigurasi dari Panel nyata). Efek `enable_icc` pada lalu lintas antar-container game **belum diuji** |
| Biner Wings diverifikasi sha256 yang dipatok sebelum dipasang; biner lama disimpan (`.prev`) | `lib/wings.sh` | **Nyata** (unduhan asli dicocokkan); **Otomatis** (ketidakcocokan ditolak) |
| Ekstensi hanya dari `extensions.lock` (sha256 dan versi); backup sebelum memasang; tidak pernah menghapus; saklar darurat | `lib/ext.sh`, `lib/ext_vet.py` | **Nyata** pada Panel nyata; **Otomatis** |
| Firewall default-deny dengan perlindungan lock-out dan dead-man switch | `lib/firewall.sh` | **Nyata** dengan ufw dan systemd asli di container uji; **Otomatis**; **belum diuji** di host VPS |
| Egress guard untuk jaringan game | `lib/firewall.sh` | **Nyata** dengan iptables asli dan lalu lintas sungguhan di network namespace; **Otomatis**; **belum diuji** di host VPS |
| Router menolak IP langsung, nama tak dikenal, dan nama kosong; server game hanya di loopback | `compose.yml`, `lib/games.py` | **Nyata** dengan handshake Minecraft pada image asli |
| Pemeriksaan jaringan preflight: subnet tumpang tindih, `pterodactyl_nw` dengan subnet berbeda, nama bridge `pterodactyl0` | `lib/preflight.sh` | **Otomatis**; **Nyata** (kasus tumpang tindih ditemukan pada uji) |
| Install server game diverifikasi lewat `launch.args` (Client API), karena Wings menandai install selesai walau skrip gagal | `lib/games.py` | **Nyata** (Wings asli di container uji) |
| Installer modpack: hash wajib, host unduhan di-allow-list, path berbahaya ditolak, alamat privat ditolak untuk `url`, kunci API tidak dikirim ke host unduhan atau log, EULA tidak pernah diterima otomatis | `eggs/modpack-installer/installer.py` | **Otomatis** (28 test unit); **Nyata** (instalasi dengan jaringan nyata) |
| Tidak ada operasi yang menghapus volume, backup, atau data Wings | seluruh `lib/` | **Otomatis** (pemindaian kode di `t_static.sh`) |
| Laporan `diagnose` dan `wings logs` menyamarkan rahasia | `lib/redact.py` | **Otomatis**; **Nyata** (kata sandi DB muncul 0 kali dalam laporan) |

## Risiko sisa

Risiko berikut tetap ada setelah semua kontrol di atas dipasang. Beberapa adalah keputusan Anda, bukan cacat.

1. **Panel 2.0 masih beta.** Skema tidak bisa diturunkan, dokumentasi berubah antar-beta, dan celah keamanan yang belum ditemukan upstream tidak tertangkap oleh kontrol di sini. Lihat [Versi dan risiko beta](architecture.md#versi-dan-risiko-beta).
2. **Wings setara root atas host.** Siapa pun yang dapat membuat server dengan image dan perintah pilihannya (administrator Panel) dapat menjalankan kode sebagai root lewat Wings. Egress guard membatasi container game, bukan Wings.
3. **cloudflared berjaringan host.** Bila konektornya dibobol, ia dapat menjangkau layanan loopback lain di host. Jangan menjalankan layanan sensitif lain di mesin yang sama yang hanya mengandalkan bind ke loopback.
4. **Cloudflare melihat lalu lintas web dalam plaintext.** Termasuk kata sandi saat login dan sesi. Ini sifat tunnel dan proxy, bukan sesuatu yang bisa diperbaiki skrip.
5. **Ekstensi Panel berjalan dengan akses penuh ke Panel.** `ext vet` hanya penyaring awal (menandai `exec`, `eval`, HTTP keluar, `unserialize`, `base64_decode`); ia bukan bukti keamanan. Tiga ekstensi terpasang telah ditinjau pada 2026-10-19 dan dikunci dengan sha256.
6. **Mod adalah kode bebas.** Egress guard memblokir jaringan privat dan host, tetapi container game masih dapat mengakses internet umum (misalnya untuk mengunduh, atau menyerang pihak lain). Pakai modpack dari sumber yang Anda percaya.
7. **Kunci CurseForge terlihat oleh proses game.** Variabel egg menjadi environment container; variabel itu disembunyikan dari pemilik server di UI, tetapi mod yang berjalan dapat membacanya. Gunakan kunci berprivilese rendah atau sumber Modrinth.
8. **IP server terlihat lewat DNS** untuk nama game (record wildcard harus *DNS only*). DDoS terhadap port 25565 hanya dimitigasi oleh batas laju koneksi router (`GAMES_CONN_RATE`), bukan oleh penyedia.
9. **Ban dan whitelist harus berdasarkan akun (UUID), bukan IP**, karena server melihat sambungan dari router (alamat lokal).
10. **Backup berada di mesin yang sama dan, tanpa `age`, tidak terenkripsi.** Ia berisi `APP_KEY` dan semua rahasia. Salin keluar server lewat saluran aman dan uji pemulihan.
11. **Konfigurasi SSH tidak dikeraskan oleh repositori ini.** Kunci SSH saja, tanpa login root, dan pembatasan sumber adalah tanggung jawab Anda (`FIREWALL_SSH_ALLOW_CIDRS` membantu).
12. **Pengaturan di UI Panel** (2FA wajib, reCAPTCHA, SMTP) dan **aturan Cloudflare** (Access, WAF, rate limit) tidak diotomatisasi dan tersimpan di basis data atau dashboard Anda.

## Rekomendasi minimum setelah instalasi

- Aktifkan 2FA untuk semua administrator dan, bila memungkinkan, wajibkan di *Admin → Settings*.
- Gunakan kunci reCAPTCHA milik sendiri.
- Pasang Cloudflare Access pada jalur admin Panel, **bukan** pada `WINGS_FQDN`. Rinciannya di [Cloudflare](cloudflare.md#5-cloudflare-access-untuk-area-admin-disarankan).
- Batasi SSH ke kunci dan, bila alamat Anda stabil, ke `FIREWALL_SSH_ALLOW_CIDRS`.
- Aktifkan enkripsi backup (`BACKUP_AGE_RECIPIENT`) dan salin backup keluar server secara terjadwal.
- Jalankan `./ptero audit` setelah setiap perubahan layanan di host, dan `./ptero update --check` secara berkala.
- Batasi siapa yang boleh membuat atau mengubah server di Panel.

## Yang tidak dilakukan repositori ini

Mengubah konfigurasi SSH atau kernel; memasang paket sistem (Docker, ufw, iptables); mengelola 2FA, reCAPTCHA, atau SMTP; backup off-site dan retensi; Cloudflare Access dan WAF; menghubungi API Cloudflare; mengelola DNS; memantau atau memberi peringatan (tidak ada alerting); memutar kata sandi basis data otomatis.

## Respons insiden dan rotasi rahasia

Prinsipnya: **jangan menghapus apa pun lebih dulu.** Hentikan penyebarannya, simpan bukti, baru pulihkan. Skrip ini tidak punya perintah yang menghapus data.

### Bila server diduga dikompromikan

1. Batasi dampaknya tanpa memutus akses Anda sendiri: `./ptero down` menghentikan Panel dan tunnel (data tetap ada) dan `sudo systemctl stop wings` menghentikan Wings. Menghentikan Wings tidak menghentikan container game yang sedang berjalan; hentikan lewat Panel atau `docker stop`. Bila host perlu diisolasi dari jaringan, lakukan dari konsol penyedia VPS, bukan dari aturan firewall yang bisa memutus SSH Anda.
2. Simpan bukti sebelum mengubah apa pun: `./ptero diagnose --output ~/laporan.txt`, `sudo journalctl -u wings > ~/wings.log`, dan salinan `backups/`. Laporan menyamarkan rahasia, tetapi baca sebelum dibagikan; `wings.log` tidak melewati penyamaran.
3. Anggap semua rahasia yang ada di server bocor (tabel di bawah) dan rotasi setelah host dipulihkan atau diganti.
4. Pulihkan ke host baru dari backup yang diambil **sebelum** insiden: [Operasi: disaster recovery](operations.md#disaster-recovery-server-baru). Jangan memulihkan ke host yang diduga terkompromi.

### Rotasi per rahasia

| Rahasia | Prosedur | Status |
|---|---|---|
| Token tunnel | Dashboard Cloudflare: tunnel → *Refresh token*; lalu `./ptero tunnel set-token` dan `./ptero up`. Menghapus tunnel mematikan jalur publik sepenuhnya | Prosedur didokumentasikan di [Cloudflare](cloudflare.md#rotasi-dan-pencabutan); **belum diuji** dengan akun nyata |
| Kunci Application API | Cabut di Panel (*Admin → Application API*), buat yang baru, `./ptero key set panel` | Sesuai fungsi Panel; **belum diuji** pencabutannya |
| Kunci Client API | Cabut di Panel (*Account → API Credentials*), buat yang baru, `./ptero key set client` | Sama |
| Kunci CurseForge | Buat ulang di console.curseforge.com, `./ptero key set curseforge`, lalu `./ptero egg install`. Server yang sudah dibuat mungkin menyimpan salinan kunci lama pada variabelnya; periksa variabel tiap server di Panel | Egg diperbarui secara **nyata**; efek pada server yang sudah ada **belum diuji** |
| Token node | Tidak ada prosedur teruji di repositori ini. Bila bocor, anggap node dan semua server di dalamnya terdampak | **Belum diuji** |
| Kata sandi MariaDB dan Redis | Tidak ada rotasi otomatis dan tidak ada prosedur teruji. Cara yang paling aman adalah instalasi baru dengan `secrets/` baru lalu `restore` dari backup | **Belum diuji** |
| `APP_KEY` | **Jangan diganti**: data terenkripsi (kunci API, token node, 2FA) menjadi tidak terbaca. Bila bocor, perlakukan semua rahasia yang disimpan Panel sebagai bocor | Tidak ada prosedur rotasi |

### Bila backup bocor

Backup berisi `APP_KEY`, `secrets/*`, dan basis data. Perlakukan semuanya sebagai bocor dan rotasi seluruh tabel di atas. Karena itu backup di luar server sebaiknya terenkripsi (`BACKUP_AGE_RECIPIENT`).

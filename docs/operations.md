# Operasi: rutinitas, backup, update, pemulihan, dan pemecahan masalah

> **Jenis:** Panduan (runbook) · **Untuk:** operator yang menjalankan stack sehari-hari · **Prasyarat:** instalasi selesai ([Instalasi lengkap](installation.md))

Halaman ini berisi prosedur yang Anda ulang selama stack berjalan. Setiap prosedur punya prasyarat, langkah, pemeriksaan hasil, dan, bila ada risiko, pemicu serta cara rollback. Semua perintah dijalankan dari direktori repositori; sintaks lengkapnya di [Referensi perintah](commands.md). Kode keluar: `0` ok, `1` gagal, `2` salah pakai, `3` preflight atau konfigurasi tidak valid, `4` ditolak demi keamanan (keadaan berisiko atau konfirmasi ditolak).

## Rutinitas

Daftar ini adalah kebiasaan minimum. Perintahnya tidak mengubah apa pun kecuali disebut.

| Kapan | Pemeriksaan | Perintah | Tindakan bila tidak sesuai |
|---|---|---|---|
| Setiap hari | Semua layanan sehat | `./ptero status` (exit 1 bila ada yang tidak sehat) | [Pemecahan masalah](#pemecahan-masalah) |
| Setiap hari | Jalur publik hidup | `./ptero verify` | [Cloudflare](cloudflare.md#6-verifikasi) |
| Setiap minggu | Tidak ada paparan baru | `./ptero audit` (exit 1 bila tak terduga) | tutup layanan itu atau bind ke `127.0.0.1` |
| Setiap minggu | Ada pembaruan atau drift | `./ptero update --check` | baca catatan rilis upstream, lalu [Update dan rollback](#update-dan-rollback) |
| Setiap minggu | Disk cukup | `df -h /var/lib/docker /var/lib/pterodactyl` | bersihkan; `MIN_FREE_DISK_GB` hanya diperiksa saat preflight |
| Setiap minggu | Backup terbaru ada dan tersalin keluar | `ls -1 backups/ \| tail -n 3` | [Backup](#backup) |
| Setiap bulan | Pemulihan benar-benar bisa dilakukan | restore ke mesin cadangan ([Disaster recovery](#disaster-recovery-server-baru)) | perbaiki prosedur backup Anda |
| Setiap bulan | Ekstensi sesuai yang dikunci | `./ptero ext list` | [Ekstensi dan tema](extensions.md) |
| Setelah mengubah firewall atau layanan di host | Hanya SSH dan port game yang terlihat | `./ptero audit` | lihat [Firewall](#firewall-egress-guard-dan-audit) |

Untuk mencadangkan secara terjadwal, pakai crontab pengguna yang berhak memakai Docker:

```bash
0 3 * * * cd /opt/pterodactyl && ./ptero backup >>/var/log/ptero-backup.log 2>&1
```

## Konfigurasi dan rahasia

Semua variabel, aturan validasi, rahasia, dan berkas yang dibuat dijelaskan di [Referensi konfigurasi](configuration.md). Tiga aturan operasional:

- `config/deploy.env` dan `secrets/` tidak dilacak Git dan tidak boleh dimasukkan ke commit, issue, atau log. Semuanya ikut `./ptero backup`.
- Setiap nilai divalidasi sebelum perintah apa pun berjalan; pesan kesalahan menyebut perbaikannya dan mendaftar semua masalah sekaligus.
- Rahasia dibuat lewat `./ptero key set ...` atau `tunnel set-token` supaya tidak pernah muncul di command line atau riwayat shell.

## Wings: dari node di Panel sampai hijau

**Prasyarat:** Panel sehat, route Wings di Cloudflare sudah ada, Docker aktif, Anda punya akses root.

1. `./ptero admin create`, lalu masuk di `https://PANEL_FQDN`.
2. *Admin → Nodes → Create* dengan nilai di [Cloudflare bagian 3](cloudflare.md#3-pengaturan-node-di-panel-sinkron-dengan-route). Tambahkan alokasi (IP dan port) hanya bila Anda akan membuat server; repositori ini tidak membuat satu pun di luar `game create`.
3. Buka tab **Configuration** dan salin YAML ke berkas di server (misalnya `~/node.yml`).
4. `sudo ./ptero wings install --config ~/node.yml`. Skrip mengunduh `wings_linux_<arch>` dari rilis GitHub yang dipatok, **menolak bila sha256 tidak sama dengan pin**, memasang ke `/usr/local/bin/wings`, menulis `/etc/systemd/system/wings.service`, memeriksa dan menambal config (tabel di bawah), memasangnya ke `/etc/pterodactyl/config.yml` (mode 600), menjalankan `systemctl enable --now wings`, dan menunggu API menjawab (batas 180 detik). Start pertama bisa memakan beberapa menit karena Wings membuat jaringan Docker.
5. `shred -u ~/node.yml`, karena berkas itu berisi token node.

**Periksa:** `./ptero status` menampilkan `wings-service active` dan `wings-api answers (HTTP 401 ...)`; halaman node di Panel menampilkan heartbeat hijau; `./ptero verify` hijau seluruhnya.

Penambalan config. Baris lain tidak disentuh, token tidak pernah dicetak, dan menjalankan ulang tidak mengubah apa pun:

| Kunci | Nilai | Alasan |
|---|---|---|
| `api.host` | `127.0.0.1` | hanya tunnel di host yang perlu menjangkaunya |
| `api.port` | `WINGS_API_PORT` | harus sama dengan origin route Cloudflare |
| `remote` | `https://PANEL_FQDN` (mode `public`) atau `http://127.0.0.1:PANEL_BIND_PORT` (`internal`) | cara Wings menghubungi Panel |
| `allowed_origins` | ditambah `https://PANEL_FQDN` | origin browser untuk WebSocket konsol |
| `api.trusted_proxies` | ditambah `127.0.0.1` | IP klien asli tercatat di log aktivitas |
| `system.sftp.bind_address` | `WINGS_SFTP_BIND` (`127.0.0.1`) | tanpa kunci ini Wings membuka SFTP di semua antarmuka; SFTP tidak lewat Cloudflare |
| `docker.network.interface` | `127.0.0.1` | dipaksa ke loopback. Alasan di kode: Docker Desktop menolak bind ke gateway bridge; dampaknya di host Linux **belum diuji** |
| `docker.network.enable_icc` | `false` | server game tidak saling berkomunikasi |
| `docker.network.interfaces.v4.subnet` dan `gateway` | dari `GAME_NET_SUBNET` (gateway = alamat pertama) | harus sama dengan subnet yang dijaga egress guard |

Dengan `WINGS_TUNING=yes`, kunci berikut ikut diubah **hanya bila sudah ada** di berkas dari Panel: `docker.container_pid_limit` 512, `system.disk_check_interval` 300, `system.websocket_log_count` 100, `system.crash_detection.detect_clean_exit_as_crash` false, `system.backups.write_limit` 50 (MiB/dtk), `system.backups.compression_level` best_speed, `api.upload_limit` 100 (MB, sama dengan batas badan permintaan Cloudflare), `throttles.lines` 2000, dan `throttles.line_reset_interval` 100. `docker.tmpfs_size` sengaja tidak diubah: nilainya membatasi `/tmp` semua container, dan batas 100 MB menggagalkan install modpack dalam uji.

Menyimpan ulang node di Panel menimpa `api.port` di sisi Panel: salin ulang config dan jalankan `sudo ./ptero wings configure <berkas>` (config lama disimpan sebagai `config.yml.bak-<waktu>`, mode 600).

## Backup

**Prasyarat:** database sehat (`./ptero status`). Opsional: paket `age` dan `BACKUP_AGE_RECIPIENT` untuk enkripsi.

```bash
./ptero backup                          # -> backups/<waktu>-manual/
./ptero backup --label sebelum-eksperimen
```

**Periksa:** perintah mencetak path backup, misalnya `backups/20261020T031500Z-manual`, dan peringatan bahwa backup berada di mesin yang sama. Direktori yang tidak berakhiran `.partial` adalah backup yang lengkap; backup yang gagal meninggalkan `*.partial` untuk diperiksa dan tidak dianggap valid.

Isi (mode 700 untuk direktori, 600 untuk berkas):

| Berkas | Isi |
|---|---|
| `db.sql.gz` | `mariadb-dump --single-transaction`, diperiksa selesai (`Dump completed`) dan terbaca |
| `panel_var.tgz` | **`APP_KEY`** dan `HASHIDS_SALT` |
| `extensions.tgz` | paket ekstensi dan aset |
| `config.tgz` | `deploy.env`, `versions.env`, `secrets/*`, dan `/etc/pterodactyl/config.yml` bila bisa dibaca |
| `MANIFEST`, `SHA256SUMS` | metadata (versi Panel, image, host) dan checksum |

- **Tidak termasuk:** data Wings dan game (`/var/lib/pterodactyl`). Backup dan berkas server dikelola Wings; pakai fitur *Backups* di Panel untuk dunia dan mod.
- **Enkripsi (opsional):** pasang `age`, set `BACKUP_AGE_RECIPIENT=age1...` (kunci publik). Backup menjadi satu berkas `.tar.age`, dan direktori plaintext yang dibuat run itu dihapus setelah enkripsi berhasil. Simpan kunci privat di luar server. Tanpa ini, backup hanya dilindungi izin berkas.
- **Retensi dan salinan di luar server tidak diotomatisasi.** Skrip tidak pernah menghapus backup. Salin keluar secara rutin, misalnya `rsync -a --chmod=D700,F600 backups/ pengguna@host-lain:/path/` atau `rclone copy backups remote:pterodactyl` (diatur sendiri), dan hapus yang lama sendiri.
- **Uji pemulihan** sesekali di mesin cadangan. Backup yang tidak pernah diuji pemulihannya belum bisa disebut backup.

## Restore

**Prasyarat:** database berjalan (di mesin baru, jalankan `./ptero setup` dulu), backup yang cocok dengan image Panel di `config/versions.env`, dan kunci privat bila terenkripsi.

```bash
./ptero restore backups/20261019T031500Z-manual
```

Urutan yang dijalankan:

1. Verifikasi checksum dan keberadaan `APP_KEY` di backup.
2. Tolak bila image Panel di backup berbeda dari `versions.env` (kecuali `--allow-version-mismatch`).
3. Tampilkan target dan minta mengetik `RESTORE`.
4. **Safety backup** keadaan sekarang (`*-pre-restore`). Bila gagal, berhenti sebelum mengubah apa pun.
5. Hentikan Panel dan tunnel, impor basis data, pulihkan `panel_var` dan ekstensi, nyalakan, dan tunggu sehat.

Bila impor basis data gagal, Panel dibiarkan **berhenti** (tidak setengah hidup) dan safety backup bisa dipulihkan. Tanpa terminal, `--yes` wajib. Untuk backup terenkripsi tambahkan `--identity /path/kunci-privat.txt`. Wings, server, dan `/var/lib/pterodactyl` tidak disentuh.

**Periksa:** `./ptero status` semuanya sehat, Anda bisa masuk di Panel, dan `./ptero verify` hijau. **Pemicu rollback:** `status` tidak sehat setelah restore atau login gagal; pulihkan safety backup `*-pre-restore` dengan perintah yang sama.

## Update dan rollback

**Prasyarat:** Anda sudah membaca catatan rilis upstream (beta berubah-ubah), `./ptero status` sehat, dan ada jendela waktu: Panel offline selama beberapa menit.

```bash
./ptero update --check          # tampilkan perbedaan antara container yang berjalan dan versions.env (hanya membaca)
./ptero update                  # backup wajib -> pull -> stop Panel -> migrate --seed -> start -> cek
sudo ./ptero wings update       # Wings terpisah; container game tetap berjalan
```

1. Ubah `config/versions.env` (tag **dan** digest; untuk Wings versi dan sha256). Cara memilih dan memverifikasinya: [Pengembangan](development.md#menaikkan-versi).
2. `update --check` mencetak image yang berbeda dan jumlah migrasi tertunda. Bila tidak ada yang berubah ia berkata `nothing to update`.
3. `update` menolak jalan bila backup gagal. `migrate --seed` mengikuti dokumentasi upstream; **seeder menimpa egg bawaan**, jadi egg yang Anda ubah harus berupa salinan.

**Periksa:** `./ptero status` sehat dengan versi baru di baris `versions:`, Anda bisa masuk, `./ptero ext list` menunjukkan ekstensi terpasang, dan `./ptero wings status` menjawab `HTTP 401` setelah `wings update`.

**Pemicu rollback:** migrasi gagal (perintah berhenti dengan pesan `migration failed`), layanan tidak sehat setelah update, Panel tidak menjawab, atau login gagal.

### Rollback

Rollback adalah memulihkan backup `pre-update` **bersama** `versions.env` lama, karena migrasi tidak bisa dibalik:

```bash
git checkout commit_versions_lama -- config/versions.env
./ptero restore backups/20261020T031500Z-pre-update
```

Wings: biner lama tersimpan sebagai `/usr/local/bin/wings.prev`.

```bash
sudo mv /usr/local/bin/wings.prev /usr/local/bin/wings && sudo systemctl restart wings
```

## Disaster recovery (server baru)

**Prasyarat:** satu backup (idealnya yang tersimpan di luar server) dan kunci privat bila terenkripsi. Data game server tidak ada di backup ini.

```bash
git clone your_repository_url_here pterodactyl && cd pterodactyl
./ptero restore-config /path/ke/backup           # mengisi config/deploy.env dan secrets/ (menolak menimpa yang ada)
./ptero setup                                    # instalasi baru dengan password lama (basis data kosong)
./ptero restore --yes /path/ke/backup            # DB + APP_KEY dari backup
sudo ./ptero wings install --config config/wings-config.restored.yml
```

Pastikan `config/versions.env` di checkout sama dengan versi di backup, atau pakai `--allow-version-mismatch` dengan sadar. Tunnel memakai token yang ikut dipulihkan; bila server lama masih hidup, hentikan konektornya agar tidak ada dua konektor dengan peran berbeda.

**Periksa:** `./ptero status`, `./ptero verify`, login di Panel, heartbeat node hijau.

## Firewall, egress guard, dan audit

```bash
./ptero firewall plan            # apa yang akan ditambahkan (hanya membaca): port SSH terdeteksi, aturan, kebijakan
sudo ./ptero firewall apply      # butuh ufw (apt install ufw); SSH diizinkan SEBELUM ufw dinyalakan
sudo ./ptero firewall confirm    # dari sesi SSH BARU, dalam FIREWALL_ROLLBACK_SECONDS (300); tanpa ini ufw mati lagi sendiri
sudo ./ptero firewall egress install   # server game vs host/LAN/metadata cloud; dipasang ulang tiap boot
./ptero firewall status ; ./ptero firewall egress status
./ptero audit                    # listener non-loopback + container yang menerbitkan port; exit 1 bila ada yang tak terduga
```

Aturan lengkapnya ada di [Arsitektur](architecture.md#matriks-port-dan-firewall). Yang perlu diingat di VPS:

- Jalankan `apply` dari sesi SSH yang sama dengan yang Anda pakai biasa; skrip membaca `SSH_CONNECTION` untuk memastikan port dan alamat sumber Anda tidak terkunci. Bila `sudo` Anda tidak meneruskan variabel itu (cek: `sudo sh -c 'echo $SSH_CONNECTION'`), pemeriksaan alamat untuk `FIREWALL_SSH_ALLOW_CIDRS` tidak dapat dilakukan; pastikan sendiri alamat Anda ada di daftar sebelum `apply`.
- **Buka sesi SSH cadangan sebelum `apply` pertama.** Dead-man switch adalah jaring pengaman kedua, bukan pengganti.
- Bila ufw sudah aktif sebelumnya, tidak ada dead-man switch (aturan Anda yang ada tidak diubah, hanya ditambah). Bila ufw mati, switch menyala; **konfirmasi** sebelum waktunya habis.
- Menambah port lain (SFTP, game lain) sengaja manual (`ufw allow ...`); `./ptero audit` menandainya `UNEXPECTED` sampai Anda menyesuaikan daftar yang diharapkan (SFTP: `WINGS_SFTP_BIND=0.0.0.0`).
- Aturan ufw tidak membatasi port yang diterbitkan Docker. Di sini semuanya terbit di `127.0.0.1`; `audit` memverifikasi hasilnya.
- Mengembalikan firewall: `sudo ufw disable` (atau baca `backups/firewall-before-*.txt` untuk keadaan sebelumnya). Skrip tidak pernah menghapus aturan.

## Ekstensi dan tema Panel

Diterapkan otomatis oleh `./ptero setup` dari `PANEL_EXTENSIONS` dan `PANEL_THEME`. Sehari-hari:

- `./ptero ext list` menampilkan terkunci versus terpasang.
- `./ptero ext install` menerapkan ulang keadaan yang diinginkan (backup dulu bila ada yang berubah).
- `./ptero ext vet FILE` memeriksa paket sebelum Anda menambahkannya ke lock.

Panel rusak setelah memasang ekstensi? Set `PANEL_EXTENSIONS_ENABLED=false` di `deploy.env`, jalankan `./ptero up`, perbaiki, lalu kembalikan ke `true`. Rinci: [Ekstensi dan tema](extensions.md).

## Server game

Pembuatan, nama host otomatis, egg, dan keamanannya: [Server Minecraft](games.md). Operasi sehari-hari:

- `./ptero games list` menampilkan nama dan port; `./ptero games sync` memaksa sinkron.
- `./ptero game create ...` membuat server baru.
- `./ptero egg install` dijalankan setelah mengubah `eggs/modpack-installer/` atau memutar kunci CurseForge; `./ptero egg build` membangun ulang berkas egg dan `egg check` memeriksanya (untuk CI).
- Backup server game (dunia, mod) adalah fitur *Backups* di Panel dan berada di sisi Wings; `./ptero backup` hanya mencakup Panel.

## Log dan diagnosa

`./ptero logs panel`, `./ptero logs -f cloudflared`, dan `./ptero logs wings` (journald). `./ptero diagnose --output ~/laporan.txt` membuat laporan (versi, konfigurasi non-rahasia, preflight, status, ekor log, hasil `verify`) dengan nilai rahasia disamarkan. Baca sekilas sebelum membagikannya; penyamaran bersifat *best effort*.

## Pemecahan masalah

| Gejala | Penyebab umum | Tindakan |
|---|---|---|
| `setup`: `configuration is not valid` | nilai di `deploy.env` atau `secrets` | pesan menyebut setiap kunci dan perbaikannya; aturan di [Referensi konfigurasi](configuration.md) |
| `setup` ditolak: "database already has Panel tables but panel_var has no APP_KEY" | volume `panel_var` hilang atau diganti, basis data masih ada | **jangan memaksa**; pulihkan `panel_var` dari backup (`./ptero restore`). Menjalankan Panel akan membuat `APP_KEY` baru dan merusak data terenkripsi |
| `setup` ditolak: pending migrations | instalasi tidak selesai atau versi berubah | `./ptero update` |
| preflight: subnet tumpang tindih | `PANEL_EDGE_SUBNET` atau `GAME_NET_SUBNET` bentrok dengan jaringan atau rute lain | ganti di `deploy.env` |
| preflight: `pterodactyl_nw` sudah ada dengan subnet berbeda | jaringan lama (misalnya dari stack sebelumnya) tidak diubah Wings | samakan `GAME_NET_SUBNET` dengan subnet itu, atau hapus jaringan yang tidak terpakai (`docker network rm`, hanya bila tidak ada container yang memakainya) |
| preflight: nama bridge `pterodactyl0` dipakai jaringan lain | jaringan lama memakai nama bridge yang dibutuhkan Wings | hapus jaringan itu bila tidak terpakai, atau jalankan Wings di host tanpanya |
| Wings gagal start: `Pool overlaps with other one on this address space` atau `conflicts with network` | dua kasus di atas | ikuti pesan preflight, lalu `sudo systemctl restart wings` |
| preflight: port dipakai | layanan lain memakai 8081/443/20241 | ganti port di `deploy.env` (untuk Wings, ubah juga origin route Cloudflare) |
| `verify`: DNS tidak resolve | zone belum Active atau route belum dibuat | [Cloudflare](cloudflare.md) |
| `verify`: 530 atau 502 | konektor mati, origin salah, Wings tidak jalan | `./ptero status`, `./ptero tunnel info`, `./ptero logs cloudflared` |
| Node merah atau "Unavailable" | skema node tidak cocok (*Use SSL* tanpa *Behind Proxy*), port tidak cocok, tunnel mati | [Cloudflare bagian 3](cloudflare.md#3-pengaturan-node-di-panel-sinkron-dengan-route); `sudo ./ptero wings configure` ulang |
| Wings menolak config: `api.ssl.enabled is true` | node bukan *Behind Proxy* | ubah node, salin config lagi |
| Konsol "Connecting…" terus | origin WebSocket diblokir (Access atau WAF di depan Wings), `allowed_origins` tidak memuat Panel | cabut Access dari `WINGS_FQDN`; `wings configure` ulang |
| Wings gagal start setelah reboot | start sebelum Panel dan tunnel siap | unit mencoba ulang tiap 10 detik tanpa batas; `journalctl -u wings` |
| Email reset kata sandi tidak terkirim | SMTP belum diatur di Panel | *Admin → Settings → Mail*; log: `./ptero logs panel` |
| `502` dari Panel saat update | Panel dihentikan sementara oleh `update` | tunggu `update` selesai |
| `confirmation required but there is no terminal` | perintah butuh konfirmasi dan stdin bukan terminal | tambahkan `--yes` bila Anda yakin |
| `firewall apply` ditolak: SSH tidak terdeteksi, atau sesi memakai port lain | sshd di balik socket activation atau port tak standar | `FIREWALL_SSH_PORTS=22` (atau port Anda) di `deploy.env` |
| `firewall apply` ditolak: dead-man switch memerlukan `systemd-run` | host tanpa systemd | jalankan di host systemd, atau `FIREWALL_ROLLBACK_SECONDS=0` dengan sadar |
| Firewall mati sendiri setelah beberapa menit | dead-man switch bekerja: `confirm` tidak dijalankan | login lagi (Anda tidak terkunci), `apply`, lalu `confirm` dari sesi baru |
| `audit` menandai `UNEXPECTED` | ada layanan lain di host yang mendengar di luar loopback | tutup layanan itu atau bind ke `127.0.0.1`; bila sah, kelola sendiri di ufw |

Masalah khusus server Minecraft (install, nama host, pemain tidak bisa tersambung): [Server Minecraft: pemecahan masalah](games.md#pemecahan-masalah).

## Menghentikan dan menghapus

`./ptero down` menghentikan container dan **menyimpan semua volume**. Penghapusan data (volume, `secrets/`, `backups/`, Wings) sengaja **tidak** disediakan oleh skrip. Lakukan sendiri, dan hanya setelah backup di luar server terverifikasi:

1. `docker volume ls`, lalu `docker volume rm pterodactyl_<nama>` untuk tiap volume.
2. `sudo systemctl disable --now wings`.
3. Hapus `/etc/pterodactyl`, `/var/lib/pterodactyl`, `/usr/local/bin/wings*`, dan `/etc/systemd/system/wings.service`.
4. Bila dipasang: `ptero-egress-guard.service`, `ptero-games-sync.service`, dan `ptero-games-sync.timer` di `/etc/systemd/system`.

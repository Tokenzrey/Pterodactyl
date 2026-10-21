# Instalasi lengkap: dari server kosong sampai Panel dan Wings berjalan

> **Jenis:** Tutorial · **Untuk:** operator yang memasang sendiri di satu VPS Linux · **Hasil:** Panel dan Wings berjalan di balik Cloudflare Tunnel, firewall aktif, backup pertama tersimpan

Tutorial ini memandu pemasangan pertama dalam 11 langkah. Setiap langkah punya tiga bagian: apa yang dikerjakan, pemeriksaan bahwa langkah itu berhasil (lengkap dengan keluaran yang diharapkan), dan jalan keluar bila gagal. Langkah yang tidak bisa diotomatisasi, yaitu semua yang menyangkut akun Cloudflare Anda, ditandai **[Anda]**; sisanya ditandai **[otomatis]** karena `./ptero` mengerjakannya.

> [!IMPORTANT]
> Panel 2.0 masih beta (`v2.0.0-beta.2` per 2026-10-20). Baca [Versi dan risiko beta](architecture.md#versi-dan-risiko-beta) sebelum mulai. Bagian firewall dan Wings di host Linux belum pernah dijalankan di VPS nyata; lihat [Verifikasi](verification.md#belum-diverifikasi). Kerjakan langkah 9 dengan sesi SSH cadangan.

Keluaran pada tutorial ini adalah teks yang dicetak oleh kode di `lib/*.sh`. Nilai seperti nama host, angka, dan versi akan berbeda pada server Anda. Pesan `[ptero] ...` ditulis ke stderr.

## Sebelum mulai

Pastikan lima hal berikut ada. Bila satu pun belum, selesaikan lebih dulu, karena tidak bisa diakali dari server.

| Kebutuhan | Cara memeriksa |
|---|---|
| Domain yang zone-nya berstatus **Active** di Cloudflare | `nslookup -type=NS contoh.com 1.1.1.1` menampilkan dua nameserver `*.ns.cloudflare.com` |
| Dua nama host satu tingkat di zone itu, misalnya `panel.contoh.com` dan `wings.contoh.com` | Keduanya belum dipakai layanan lain |
| Server Linux yang didukung (Ubuntu 22.04/24.04/26.04 atau Debian 12/13), akses SSH dengan sudo | `cat /etc/os-release` |
| Docker Engine dan Compose v2 (2.20 atau lebih baru) | `docker compose version --short` mencetak `2.20.0` atau lebih |
| Jam sistem tersinkron | `timedatectl show -p NTPSynchronized --value` mencetak `yes` |

Siapkan juga sesi SSH kedua yang tetap terbuka selama langkah 9. Itu jaring pengaman bila aturan firewall salah.

## Langkah 1: siapkan host

**[Anda]** Pasang Docker Engine mengikuti [dokumentasi Docker](https://docs.docker.com/engine/install/) (skrip ini tidak memasang Docker) dan, untuk langkah firewall, ufw dan iptables:

```bash
sudo apt install ufw iptables
sudo usermod -aG docker "$USER"      # lalu keluar dan masuk lagi supaya grup berlaku
```

**Periksa:**

```bash
docker info --format '{{.ServerVersion}}'
docker compose version --short
```

Kedua perintah mencetak nomor versi. Bila `docker info` menolak karena izin, Anda belum masuk ulang setelah `usermod`.

## Langkah 2: ambil repositori dan buat konfigurasi awal

**[otomatis]**

```bash
git clone your_repository_url_here pterodactyl && cd pterodactyl
chmod +x ptero          # hanya bila bit eksekusi hilang
./ptero init
```

`init` membuat `config/deploy.env` dari contoh (mode 600) serta `secrets/db_password` dan `secrets/redis_password` berisi 48 karakter heksadesimal acak. Berkas yang sudah ada tidak disentuh, jadi aman dijalankan ulang.

**Periksa.** Keluarannya:

```text
[ptero] created config/deploy.env from the example
[ptero] generated secrets/db_password
[ptero] generated secrets/redis_password

Next:
  1. Edit config/deploy.env: PANEL_FQDN, WINGS_FQDN, ADMIN_EMAIL, PTERO_ACCEPT_BETA.
  2. Cloudflare (once, in the dashboard): see docs/cloudflare.md. Create a tunnel, then:  ./ptero tunnel set-token
  3. ./ptero setup
```

Pada eksekusi ulang, tiga baris pertama menjadi `... already exists: left untouched`.

## Langkah 3: isi konfigurasi

**[Anda]** Edit `config/deploy.env` dan isi empat nilai wajib:

```ini
PANEL_FQDN=panel.contoh.com
WINGS_FQDN=wings.contoh.com
ADMIN_EMAIL=admin@contoh.com
PTERO_ACCEPT_BETA=yes
```

Isi juga `APP_TIMEZONE` (misalnya `Asia/Jakarta`; bawaannya `UTC`). Nilai lain punya bawaan yang aman; artinya satu per satu ada di [Referensi konfigurasi](configuration.md). Tiga hal yang perlu Anda pahami sekarang:

- Nama contoh `example.com`, `example.org`, `example.net`, `localhost`, `invalid`, dan `test` ditolak validasi.
- `PANEL_FQDN` dan `WINGS_FQDN` harus berbeda dan satu tingkat di bawah zone Anda.
- File ini di-*parse*, bukan dieksekusi. Karakter yang diizinkan di nilai adalah huruf, angka, dan `. _ : / @ , + = % -`.

**Periksa** dengan preflight, yang hanya membaca:

```bash
./ptero preflight
```

Contoh keluaran yang sehat:

```text
Preflight (read-only):
  [ ok ] OS ubuntu 24.04 (supported by upstream Wings docs)
  [ ok ] architecture x86_64
  [ ok ] required commands present
  [ ok ] Docker daemon reachable (29.8.2)
  [ ok ] Docker Compose 5.6.0
  [ ok ] 120 GB free on /var/lib/docker
  [ ok ] 40 GB free on /home/ops/pterodactyl
  [ ok ] memory available: 3012 MB
  [ ok ] PANEL_BIND_PORT 8081 is free
  [ ok ] TUNNEL_METRICS_PORT 20241 is free
  [ ok ] WINGS_API_PORT 443 is free
  [ ok ] PANEL_EDGE_SUBNET 172.29.250.0/24 overlaps no Docker network or host route
  ...
Result: 0 failed, 0 warnings
```

Baris `[FAIL]` menghentikan `setup` (kode keluar 3) dan menyebut perbaikannya. Pesan konfigurasi yang tidak valid mendaftar setiap kunci yang salah sekaligus. Jika port atau subnet bentrok, ubah nilainya di `deploy.env`; daftar penyebab umum ada di [Operasi: pemecahan masalah](operations.md#pemecahan-masalah).

## Langkah 4: buat tunnel di Cloudflare

**[Anda]** Ini langkah yang memakan waktu paling lama karena menyangkut akun Anda. Ikuti [Cloudflare](cloudflare.md) bagian 0 dan 1: pastikan zone Active, buat *named tunnel* (bukan quick tunnel), lalu salin token dari perintah `docker run ... --token` yang ditampilkan dashboard. Jangan menjalankan perintah itu.

Di server:

```bash
./ptero tunnel set-token
```

Tempel token pada prompt tersembunyi. Menempel seluruh baris perintah juga boleh: skrip memotong bagian setelah `--token`. Token divalidasi (base64 berisi kunci `a`, `t`, `s`) dan disimpan di `secrets/tunnel_token` dengan mode 600.

**Periksa:**

```text
[ptero] saved secrets/tunnel_token (mode 600). Apply with: ./ptero up
```

Jika muncul `that is not a Cloudflare tunnel token`, yang tertempel bukan token. Salin ulang hanya nilainya.

## Langkah 5: pasang dan nyalakan stack Panel

**[otomatis]**

```bash
./ptero setup
```

`setup` menjalankan, berurutan: validasi konfigurasi dan rahasia, preflight, `docker compose pull` untuk image yang dipatok, MariaDB dan Redis (menunggu sehat, batas 240 detik), deteksi instalasi baru atau yang sudah ada, `migrate --seed` hanya pada basis data kosong, Panel dan tunnel (batas 300 detik), penerapan ekstensi dan tema, dan, bila `GAMES_ENABLED=yes`, impor egg modpack.

Pada instalasi yang sudah ada, `setup` menolak melanjutkan bila basis data berisi tabel Panel tetapi `APP_KEY` hilang, atau bila ada migrasi tertunda. Keduanya melindungi data terenkripsi; jangan memaksanya (lihat [Operasi: pemecahan masalah](operations.md#pemecahan-masalah)).

**Periksa.** Keluaran akhirnya:

```text
Panel stack is up.
  Panel (loopback):   http://127.0.0.1:8081
  Panel (public):     https://panel.contoh.com   (after the Cloudflare route exists: ./ptero tunnel info)

Still manual:
  - first administrator:           ./ptero admin create
  ...
```

Lalu:

```bash
./ptero status
```

```text
SERVICE        STATE
database       healthy
cache          healthy
panel          healthy
cloudflared    healthy
panel-http     ok (127.0.0.1:8081)
wings-service  not installed (sudo ./ptero wings install)

versions: panel v2.0.0-beta.2, wings v1.13.4
```

Semua baris layanan harus `healthy` (atau `running` untuk `mc-router`). Bila tidak, `./ptero logs <layanan>` menunjukkan sebabnya.

**Jalan keluar.** `./ptero down` menghentikan container dan menyimpan semua volume. `setup` aman dijalankan ulang setelah memperbaiki masalah.

## Langkah 6: tambahkan dua route di Cloudflare

**[Anda]** Jalankan `./ptero tunnel info`; perintah mencetak dua pasangan nama host dan Service URL yang persis sesuai konfigurasi Anda. Tambahkan keduanya sebagai *Published application route* pada tunnel:

| Hostname | Service URL |
|---|---|
| `panel.contoh.com` | `http://127.0.0.1:8081` |
| `wings.contoh.com` | `http://127.0.0.1:443` |

Skema `http://` wajib ada. TLS berakhir di Cloudflare; origin hanya mendengar di loopback. Rincian dan jebakan umum: [Cloudflare](cloudflare.md) bagian 2.

**Periksa:**

```bash
./ptero verify
```

```text
Public path checks (no credentials):
  [ ok ] DNS resolves: panel.contoh.com
  [ ok ] DNS resolves: wings.contoh.com
  [ ok ] Panel login page over HTTPS: 200
  [FAIL] Wings: HTTP 502 from Cloudflare: Wings is not running on 127.0.0.1:443 or the route origin is wrong
```

Baris Wings **diharapkan gagal** (502 atau 530) sampai langkah 8, karena Wings belum berjalan. Tiga baris pertama harus `[ ok ]`. Bila DNS tidak resolve, zone belum Active atau route belum dibuat. Bila Panel mengembalikan 530/502/1033, konektor mati atau origin salah.

## Langkah 7: buat administrator pertama

**[Anda]** Jalankan dari terminal interaktif:

```bash
./ptero admin create
```

Jawab `yes` ketika ditanya apakah pengguna adalah administrator. Kata sandi diketik pada prompt tersembunyi milik Panel dan tidak pernah menjadi argumen perintah. Perintah menolak berjalan tanpa terminal.

**Periksa:** buka `https://panel.contoh.com` dan masuk. Aktifkan 2FA untuk akun ini dari pengaturan akun.

## Langkah 8: buat node dan pasang Wings

**[Anda]** Di Panel: *Admin → Nodes → Create*. Nilai yang harus cocok dengan route Cloudflare:

| Kolom | Nilai |
|---|---|
| FQDN | `wings.contoh.com` (`WINGS_FQDN`) |
| Communicate over SSL | *Use SSL* |
| Behind Proxy | *Behind Proxy* |
| Daemon Port | `443` |
| SFTP port | `2022` |

Penjelasan mengapa kombinasi ini wajib: [Cloudflare](cloudflare.md#3-pengaturan-node-di-panel-sinkron-dengan-route). Simpan node, buka tab **Configuration**, dan salin YAML ke sebuah berkas di server, misalnya `~/node.yml`.

**[otomatis]** (butuh root):

```bash
sudo ./ptero wings install --config ~/node.yml
shred -u ~/node.yml        # berkas itu masih berisi token node
```

Perintah meminta konfirmasi, lalu mengunduh biner Wings yang dipatok, **menolak memasangnya bila sha256 tidak sama dengan pin**, memasang biner dan unit systemd, memeriksa serta menambal konfigurasi, menyimpannya di `/etc/pterodactyl/config.yml` (mode 600), menyalakan layanan, dan menunggu API menjawab (batas 180 detik). Start pertama bisa memakan beberapa menit karena Wings membuat jaringan Docker.

> [!NOTE]
> **Docker Desktop (WSL2).** Perintah ini butuh Docker Engine dengan systemd. Docker Desktop tidak punya `docker.service`, dan tunnel (jaringan host) berjalan di VM Docker Desktop sehingga tidak menjangkau Wings di distro. Di sana pakai `WINGS_MODE=container` dan `./ptero wings install --config ~/node.yml` tanpa sudo: [Operasi: Wings sebagai container](operations.md#wings-sebagai-container-wings_modecontainer).

**Periksa:**

```text
[ptero] downloading Wings v1.13.4 (amd64)
[ptero] installed /etc/systemd/system/wings.service
[ptero] installed /etc/pterodactyl/config.yml (mode 600)
[ptero] Wings is starting; the first start can take several minutes while Docker networks are created
```

Lalu `./ptero status` menampilkan `wings-service active` dan `wings-api answers (HTTP 401 ...)`; `401` adalah jawaban normal tanpa kredensial. `./ptero verify` kini harus hijau seluruhnya, dan halaman node di Panel menampilkan heartbeat hijau.

**Jalan keluar.** Biner lama disimpan sebagai `/usr/local/bin/wings.prev` ketika Anda memperbarui nanti. Konfigurasi lama disimpan sebagai `config.yml.bak-<waktu>`. Bila Wings tidak mau start, lihat `./ptero logs wings` dan [Operasi: Wings](operations.md#wings-dari-node-di-panel-sampai-hijau).

## Langkah 9: kunci server

**[otomatis, dengan sesi SSH cadangan]** Langkah ini menyalakan firewall di server jarak jauh. Kerjakan dengan hati-hati.

1. Lihat rencana tanpa mengubah apa pun:

   ```bash
   ./ptero firewall plan
   ```

   ```text
   SSH ports kept open: 22
   Policy: default deny incoming, allow outgoing. Docker/forwarding policy is not touched.
   Rules this tool adds (existing rules are left alone):
     ufw allow 22/tcp   # ptero: ssh
     (games disabled: no game port will be opened)
   Everything else listens on 127.0.0.1 only (Panel, Wings API, SFTP by default, tunnel metrics).
   ```

   Pastikan port SSH Anda ada di daftar. Bila deteksi salah, set `FIREWALL_SSH_PORTS` di `deploy.env`.

2. Terapkan dari sesi SSH yang Anda pakai biasa (butuh root):

   ```bash
   sudo ./ptero firewall apply
   ```

   Skrip menampilkan rencana dan meminta konfirmasi, memeriksa port dan alamat sesi Anda, menyimpan keadaan sebelumnya di `backups/firewall-before-<waktu>.txt`, mengizinkan SSH **sebelum** ufw dinyalakan, memverifikasi dari aturan aktif bahwa port SSH diterima, lalu menyalakan *dead-man switch* selama `FIREWALL_ROLLBACK_SECONDS` (bawaan 300 detik).

3. **Buka sesi SSH baru** dari komputer Anda dan pastikan login berhasil. Dari sesi baru itu:

   ```bash
   sudo ./ptero firewall confirm
   ```

   ```text
   [ptero] dead-man switch cancelled: the firewall stays enabled. Check: ./ptero audit
   ```

   Bila Anda tidak bisa masuk, jangan lakukan apa-apa: ufw mati sendiri setelah waktu habis dan Anda dapat masuk lagi.

4. Pasang egress guard (agar server game tidak menjangkau host, LAN, atau metadata cloud) dan jalankan audit:

   ```bash
   sudo ./ptero firewall egress install
   ./ptero audit
   ```

   ```text
   Listeners reachable beyond loopback:
     ok         tcp 0.0.0.0:22
   Audit clean: only expected ports are reachable.
   ```

**Jalan keluar.** `sudo ufw disable` mengembalikan keadaan tanpa firewall. Skrip tidak pernah menghapus aturan Anda. Bila `apply` menolak karena SSH tidak terdeteksi atau sesi memakai port di luar daftar, itu perlindungan lock-out; ikuti pesannya. Detail: [Operasi: firewall](operations.md#firewall-egress-guard-dan-audit) dan [Keamanan](security.md).

## Langkah 10: backup pertama

**[otomatis]**

```bash
./ptero backup --label setelah-instalasi
```

**Periksa:** perintah mencetak path seperti `backups/20261020T031500Z-setelah-instalasi` dan peringatan bahwa backup berada di mesin yang sama. Salin keluar server (backup berisi `APP_KEY` dan rahasia, jadi gunakan saluran yang aman atau aktifkan enkripsi `age`): [Operasi: backup](operations.md#backup). Backup yang tidak pernah diuji pemulihannya belum bisa disebut backup.

## Langkah 11: server Minecraft (opsional)

Bila Anda ingin membuat server game dari modpack, lanjutkan ke [Server Minecraft](games.md). Langkah intinya: `GAMES_ENABLED=yes` dan `GAMES_DOMAIN` di `deploy.env`, satu record DNS wildcard, kunci API Panel, lalu `./ptero game create`.

## Daftar periksa akhir

| Pemeriksaan | Perintah | Hasil yang diharapkan |
|---|---|---|
| Semua layanan sehat | `./ptero status` | tidak ada baris bermasalah; exit 0 |
| Jalur publik | `./ptero verify` | semua `[ ok ]`; exit 0 |
| Tidak ada paparan tak terduga | `./ptero audit` | `Audit clean`; exit 0 |
| Firewall aktif dan dikonfirmasi | `./ptero firewall status` | `Status: active`; tidak ada timer `ptero-firewall-rollback` yang tertunda |
| Egress guard terpasang | `./ptero firewall egress status` | semua baris `ok` |
| Backup ada dan tersalin keluar | `ls backups/` | direktori atau `.tar.age` ber-timestamp; salinannya ada di mesin lain |
| 2FA aktif untuk administrator | UI Panel | aktif |
| Panel tidak menampilkan error di log | `./ptero logs panel --tail 50` | tidak ada error berulang |

Setelah ini, lanjut ke [Operasi](operations.md): rutinitas harian, update, dan pemulihan.

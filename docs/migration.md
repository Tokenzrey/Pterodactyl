# Memindahkan dari stack lama (`~/pterodactyl-stack`, WSL2/Docker Desktop)

> **Jenis:** Panduan · **Untuk:** pemilik stack WSL2 lama yang ingin pindah ke server Linux · **Status verifikasi:** **belum diuji** pada data nyata

Dokumen ini memetakan stack lama ke repositori ini dan menjelaskan dua jalur: pindah ke server Linux baru (disarankan) atau mengadopsi volume lama di host Docker Linux yang sama. Yang dipindahkan adalah data Panel (basis data dan `APP_KEY`); file game server tidak ikut.

> [!IMPORTANT]
> Direktori `~/pterodactyl-stack` ada di WSL milik Anda, bukan di workspace ini. Dokumen ini disusun dari panduan lama ([Pterodactyl-Docker-WSL2-Deployment-Guide.md](Pterodactyl-Docker-WSL2-Deployment-Guide.md)) dan konfigurasi yang terdokumentasi di dalamnya. **Tidak ada berkas lama yang dibaca, dipindahkan, atau diubah oleh pekerjaan ini**, dan prosedur di bawah **belum diuji** pada data nyata. Jalankan dengan backup lama yang sudah Anda salin keluar.

## Daftar periksa sebelum mulai

- [ ] Backup lama (`./stack.sh backup`) sudah dibuat **dan disalin keluar** dari mesin lama.
- [ ] Versi Panel di stack lama sama dengan pin di `config/versions.env` (`v2.0.0-beta.2`, digest `b3f1229a...`). Bila berbeda, dump tidak cocok dengan skema yang diimpor.
- [ ] Server baru sudah memenuhi [prasyarat](../README.md#prasyarat) dan Anda sudah menyelesaikan [Instalasi lengkap](installation.md) sampai `./ptero setup` berhasil tanpa error.
- [ ] Anda tahu apakah hostname berubah. Bila ya, siapkan perubahan `deploy.env`, route Cloudflare, FQDN node, reCAPTCHA, dan Access ([Cloudflare](cloudflare.md)).
- [ ] Anda paham bahwa file game server (dunia, mod) tidak ikut dan harus dipindahkan terpisah.

## Pemetaan

| Stack lama | Di repositori ini |
|---|---|
| `compose.yml` (Panel, MariaDB, Redis, cloudflared, Wings, egress-guard, autosuspend) | `compose.yml` (Panel, MariaDB, Redis, cloudflared; mc-router opsional). Wings jadi service systemd di host. Egress guard dibawa sebagai `firewall egress`; autosuspend tidak dibawa |
| `.env` (`DB_PASSWORD`, `REDIS_PASSWORD`, `CF_TUNNEL_TOKEN`, `PANEL_FQDN`, `WINGS_FQDN`, ...) | `secrets/db_password`, `secrets/redis_password`, `secrets/tunnel_token` dan `config/deploy.env` |
| `stack.sh up/down/status/backup` | `./ptero up/down/status/backup` (ditambah restore, update, verify, diagnose) |
| `backups/panel-<waktu>.sql.gz` dan `panel_var-<waktu>.tgz` | backup `./ptero` (satu direktori berisi keduanya dan manifest). Format lama bisa diimpor manual (di bawah) |
| `wings/etc/config.yml` (disesuaikan untuk Docker Desktop: `interface: 127.0.0.1`, subnet `172.22.0.0/16`, port 443) | **jangan disalin**; buat ulang dari tab Configuration node, lalu `wings install --config` menambalnya |
| `themes/unix`, `ext/` (`announcements`, `custom-buttons`), tema aktif `unix`, env baseline Panel (retensi log, telemetri, saklar ekstensi), tuning Wings | **dibawa dan diotomatisasi**: `extensions/` (lock sha256 yang cocok dengan berkas lama, sumber dan paket tema `unix`), `PANEL_EXTENSIONS`/`PANEL_THEME`, `./ptero setup` ([Ekstensi dan tema](extensions.md)). Pada migrasi data, ekstensi di volume ikut backup dan restore |
| `tools/` (modpack, mc-deploy, SRV, autosuspend) | digantikan oleh egg modpack dan `game create` ([Server Minecraft](games.md)); alat lama diarsipkan dan tidak dipakai |
| Volume `pterodactyl_*` | nama yang sama bila `PTERO_PROJECT=pterodactyl` (bawaan); lihat "Di host yang sama" |

Port lama `127.0.0.1:8081` dan `127.0.0.1:8080→443`, serta jaringan `ptero_edge` (172.20.0.0/24) dan `ptero_backend` (172.21.0.0/24), digantikan oleh `PANEL_BIND_PORT`, `WINGS_API_PORT`, dan jaringan project `pterodactyl_edge` dan `pterodactyl_backend`.

Versi Panel stack lama (`v2.0.0-beta.2`, digest `b3f1229a...`) sama dengan pin di `config/versions.env`, jadi dump dari stack lama cocok dengan skema yang akan diimpor.

## Ke server Linux baru (jalur yang disarankan)

Di mesin lama:

```bash
cd ~/pterodactyl-stack
./stack.sh backup                       # menghasilkan backups/panel-<waktu>.sql.gz dan panel_var-<waktu>.tgz
# salin keduanya ke server baru (scp/rsync); keduanya berisi rahasia (APP_KEY)
./stack.sh down                         # hentikan konektor lama SEBELUM menyalakan yang baru memakai token yang sama
```

Di server baru, ikuti [Instalasi lengkap](installation.md) sampai `./ptero setup` selesai tanpa error, lalu impor:

```bash
cd ~/pterodactyl
./ptero compose stop panel cloudflared
gunzip -c /path/panel-<waktu>.sql.gz | ./ptero compose exec -T database \
  sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'
docker run --rm -v pterodactyl_panel_var:/ptero_vol -v /path:/ptero_in:ro \
  docker.io/library/alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc \
  sh -c 'tar xzf /ptero_in/panel_var-<waktu>.tgz -C /ptero_vol'
./ptero up
./ptero backup --label setelah-migrasi  # segera ambil backup dalam format baru
```

Kemudian buat ulang konfigurasi Wings: di Panel buka node → **Configuration** → `sudo ./ptero wings install --config <berkas>`.

**Periksa:**

- `./ptero status` semuanya sehat dan `./ptero verify` hijau.
- Anda bisa masuk dengan akun lama (bukti bahwa `APP_KEY` dan basis data cocok).
- Pengaturan Panel yang tersimpan (SMTP, 2FA, captcha) ada. Kata sandi SMTP terenkripsi dengan `APP_KEY` yang ikut diimpor.
- `./ptero ext list` menunjukkan ekstensi dan tema yang sama.
- Heartbeat node hijau setelah `wings install`.

**Pemicu rollback:** login gagal setelah impor (biasanya `APP_KEY` tidak cocok dengan dump), atau `status` tidak sehat. Karena mesin lama tidak diubah, rollback adalah mematikan server baru dan menyalakan kembali stack lama (`./stack.sh up`) setelah memastikan konektor baru berhenti (`./ptero down`), sehingga hanya satu konektor yang memakai token tunnel.

Yang perlu Anda ketahui:

- Dump membawa **rekaman** server, node, dan alokasi dari Panel lama, tetapi file game server ada di Wings atau volume lama dan **tidak** ikut. Server di Panel baru akan tampak ada tetapi kosong. Hapus rekaman yang tidak Anda pindahkan, atau pindahkan file game secara terpisah (di luar repositori ini). Perilaku Wings baru terhadap rekaman server tanpa file belum diuji.
- Alokasi lama (`127.0.0.1:25565`) bermakna di Docker Desktop; di Linux nyata pilih IP dan port yang Anda inginkan saat nanti membuat server. Untuk server Minecraft, alokasinya harus `127.0.0.1` di rentang `GAMES_BACKEND_FIRST` sampai `GAMES_BACKEND_LAST` agar dirutekan ([Server Minecraft](games.md)).
- Bila hostname berubah: ubah `deploy.env`, route Cloudflare, FQDN node, reCAPTCHA, dan Access ([Cloudflare](cloudflare.md)).

## Di host yang sama (mengadopsi volume lama)

Hanya bila host lama adalah Linux Docker biasa. **Belum diuji.** Docker Desktop dan WSL2 **bukan** target repositori ini (Wings sebagai service systemd, dan upstream menyatakan Windows tidak didukung).

1. `./stack.sh backup` dan salin backup keluar. Lalu `./stack.sh down` (menyimpan volume).
2. `./ptero init`, lalu ganti isi `secrets/db_password` dan `secrets/redis_password` dengan nilai `DB_PASSWORD` dan `REDIS_PASSWORD` dari `.env` lama (kata sandi MariaDB tersimpan di volume dan **harus** sama; edit dengan editor, mode tetap 600). Isi `deploy.env` dan token.
3. `./ptero setup`: akan mendeteksi basis data yang sudah berisi dan `APP_KEY` yang ada, dan tidak migrate maupun seed.
4. Wings: lihat bagian sebelumnya.

Bila langkah 3 menolak dengan pesan `APP_KEY` atau migrasi tertunda, jangan paksa; ikuti pesannya. Jaringan `pterodactyl_nw` dari Wings lama dapat membuat preflight gagal (subnet berbeda atau nama bridge `pterodactyl0`); lihat [Operasi: pemecahan masalah](operations.md#pemecahan-masalah).

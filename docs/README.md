# Dokumentasi

> **Jenis:** Indeks · **Untuk:** semua pembaca · **Diperbarui:** 2026-10-20

Halaman ini memetakan seluruh dokumentasi repositori berdasarkan tujuan Anda: memasang dari nol, menjalankan sehari-hari, memahami desain dan keamanan, memindahkan data dari stack lama, atau memelihara kode. Semua halaman memakai konvensi dan label verifikasi yang sama (lihat bagian akhir halaman ini), jadi Anda selalu bisa membedakan apa yang sudah dijalankan pada komponen asli dari apa yang baru dirancang.

## Mulai dari mana

| Tujuan | Baca | Jenis |
|---|---|---|
| Memasang Panel + Wings di VPS dari nol | [Instalasi lengkap](installation.md) | Tutorial |
| Menjalankan Wings sebagai container (Docker Desktop, WSL2) | [Operasi: Wings sebagai container](operations.md#wings-sebagai-container-wings_modecontainer) | Panduan |
| Menyiapkan Cloudflare Tunnel, route, dan Access | [Cloudflare](cloudflare.md) | Panduan |
| Membuat server Minecraft dari modpack | [Server Minecraft](games.md) | Panduan |
| Menjalankan, mencadangkan, memperbarui, memulihkan | [Operasi](operations.md) | Panduan (runbook) |
| Mencari sintaks, hak akses, dan efek sebuah perintah | [Referensi perintah](commands.md) | Referensi |
| Mencari arti sebuah variabel, rahasia, atau berkas | [Referensi konfigurasi](configuration.md) | Referensi |
| Memahami desain, port, alur traffic, dan versi | [Arsitektur](architecture.md) | Konsep |
| Menilai keamanan, risiko sisa, dan respons insiden | [Keamanan](security.md) | Konsep + panduan |
| Mengetahui apa yang sudah diuji dan apa yang belum | [Verifikasi](verification.md) | Referensi |
| Memindahkan data dari stack lama (WSL2/Docker Desktop) | [Migrasi](migration.md) | Panduan |
| Mengelola ekstensi dan tema Panel | [Ekstensi dan tema](extensions.md) | Panduan |
| Membangun extension Panel sendiri (backend, frontend, uji, paket) | [Extension Pterodactyl](extensions/README.md) | Panduan + referensi |
| Mengubah kode, menaikkan versi, menjalankan test | [Pengembangan](development.md) | Panduan |
| Menemukan arti sebuah istilah | [Glosarium](glossary.md) | Referensi |

## Jalur baca per peran

- **Operator yang memasang sendiri.** [README](../README.md), lalu [Instalasi lengkap](installation.md), lalu [Cloudflare](cloudflare.md) bila Anda belum punya tunnel. Sebelum membuka server ke publik, baca [Keamanan](security.md) dan bagian "Belum diverifikasi" di [Verifikasi](verification.md).
- **Operator harian.** Simpan [Operasi](operations.md) dan [Referensi perintah](commands.md) sebagai rujukan. Bagian "Rutinitas" di Operasi berisi daftar pemeriksaan harian, mingguan, dan bulanan.
- **Peninjau keamanan.** [Arsitektur](architecture.md) untuk batas kepercayaan, [Keamanan](security.md) untuk kontrol beserta status verifikasinya, [Verifikasi](verification.md) untuk bukti dan celahnya.
- **Pemelihara kode.** [Pengembangan](development.md) untuk struktur, test, dan prosedur menaikkan versi, lalu [Referensi konfigurasi](configuration.md) untuk aturan validasi.

## Mencari berdasarkan gejala

| Gejala | Lihat |
|---|---|
| `./ptero setup` menolak berjalan atau konfigurasi tidak valid | [Operasi: pemecahan masalah](operations.md#pemecahan-masalah), [Referensi konfigurasi](configuration.md) |
| `./ptero verify` gagal: DNS, 502, 530 | [Cloudflare: verifikasi](cloudflare.md#6-verifikasi) |
| Node merah atau konsol server tidak tersambung | [Operasi: pemecahan masalah](operations.md#pemecahan-masalah), [Cloudflare: pengaturan node](cloudflare.md#3-pengaturan-node-di-panel-sinkron-dengan-route) |
| Route Wings `502` di Docker Desktop, atau `wings install` menolak karena `docker.service` | [Operasi: Wings sebagai container](operations.md#wings-sebagai-container-wings_modecontainer) |
| Pemain tidak bisa tersambung ke server Minecraft | [Server Minecraft: pemecahan masalah](games.md#pemecahan-masalah) |
| Install modpack gagal, `launch.args is missing`, `No space left on device` | [Server Minecraft: pemecahan masalah](games.md#pemecahan-masalah) |
| Firewall mati sendiri, `firewall apply` ditolak | [Operasi: firewall](operations.md#firewall-egress-guard-dan-audit), [Keamanan](security.md) |
| Panel rusak setelah memasang ekstensi | [Ekstensi dan tema](extensions.md#cara-kerja-dan-jaminan) |
| Rahasia atau token bocor | [Keamanan: respons insiden](security.md#respons-insiden-dan-rotasi-rahasia) |
| Update gagal, perlu rollback | [Operasi: update dan rollback](operations.md#update-dan-rollback) |

## Arsip

Dua berkas lama dan direktori `tools/` berasal dari stack Windows/WSL2 sebelumnya. Isinya adalah catatan pengalaman nyata, tetapi **tidak dipakai** oleh deployment ini, **tidak dipelihara**, dan sebagian instruksinya tidak berlaku di Linux.

| Berkas | Isi |
|---|---|
| [Pterodactyl-Docker-WSL2-Deployment-Guide.md](Pterodactyl-Docker-WSL2-Deployment-Guide.md) | Panduan lengkap stack lama, termasuk langkah membangun ulang tema `unix` (bagian 7.3) |
| [Analisis Dokumentasi Pterodactyl 2.0 Beta_ Instalasi, Upgrade, dan API.md](Analisis%20Dokumentasi%20Pterodactyl%202.0%20Beta_%20Instalasi%2C%20Upgrade%2C%20dan%20API.md) | Catatan analisis dokumentasi upstream |

## Konvensi dokumentasi

**Jenis halaman.** Setiap halaman menyebut jenisnya di bawah judul: Tutorial (belajar sambil mengerjakan, urutan tetap), Panduan (menyelesaikan satu tugas), Referensi (lengkap dan netral), Konsep (menjelaskan alasan), atau gabungan yang disebut jelas. Setiap halaman dibuka dengan satu paragraf ringkasan.

**Label status verifikasi.** Klaim tentang perilaku sistem memakai tiga label yang sama di seluruh dokumen:

| Label | Arti |
|---|---|
| **Nyata** | Dijalankan pada komponen asli (image atau biner yang dipatok) di mesin uji. Mesin uji bukan VPS Anda; lingkungannya dicatat di [Verifikasi](verification.md) |
| **Otomatis** | Dicakup `bash tests/run.sh` dengan tiruan (`docker`, `ufw`, `iptables`, Panel palsu) |
| **Belum diuji** | Dirancang berdasarkan dokumentasi upstream atau bacaan kode, belum dijalankan |

**Format.**

- Perintah yang mengubah host (memasang paket, unit systemd, aturan firewall) ditandai **butuh root** dan ditulis dengan `sudo`.
- Contoh nama memakai `contoh.com`. Nilai rahasia pada contoh memakai placeholder bergaya `your_token_here`; jangan menempelkan rahasia asli ke dokumen, issue, atau log.
- Keluaran perintah pada halaman Tutorial diambil dari pesan di kode (`lib/*.sh`), bukan dikarang. Bila versi Anda mencetak teks yang berbeda, kodenya yang benar; laporkan perbedaannya.
- Tanggal ditulis lengkap (2026-10-20) dan versi disebut persis, karena Panel 2.0 masih beta dan dokumen upstream-nya berubah.
- Peringatan memakai callout GFM: `> [!NOTE]`, `> [!IMPORTANT]`, `> [!WARNING]`.

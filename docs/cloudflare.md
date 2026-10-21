# Cloudflare: langkah satu kali dan batasannya

> **Jenis:** Panduan · **Untuk:** operator yang menyiapkan tunnel dan DNS · **Status verifikasi:** langkah di dashboard **belum diuji** dengan akun nyata; sisi server (`tunnel info`, `verify`, validasi token) **diuji otomatis** dengan tiruan, dan cloudflared asli hanya diuji menolak token tidak valid dengan bersih

Panel dan Wings tidak membuka port web di VPS; keduanya dijangkau lewat Cloudflare Tunnel. Halaman ini memandu bagian yang harus Anda kerjakan di dashboard Cloudflare, karena memerlukan akun dan otorisasi Anda: mengaktifkan zone, membuat tunnel, menambahkan dua route, dan, bila mau, Access dan WAF. Repositori ini tidak meminta API token Cloudflare dan tidak menghubungi API Cloudflare. Sisi server yang otomatis hanya menjalankan konektor dengan token Anda dan mencetak apa yang harus diisi (`./ptero tunnel info`).

Nama menu Cloudflare berubah dari waktu ke waktu (*Zero Trust → Networks → Tunnels* versus *Networking → Tunnels*). Panduan resmi: [Create a remotely-managed tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/).

## Pembagian pekerjaan

| Langkah | Siapa | Bagian |
|---|---|---|
| Memiliki domain, mengaktifkan zone | **Anda** | [0](#0-zone-harus-active) |
| Membuat named tunnel dan menyalin token | **Anda** | [1](#1-buat-named-tunnel-bukan-quick-tunnel) |
| Menyimpan token dan menjalankan konektor | otomatis (`tunnel set-token`, `up`) | [1](#1-buat-named-tunnel-bukan-quick-tunnel) |
| Menambahkan dua route | **Anda** (nilai dicetak `tunnel info`) | [2](#2-dua-route-published-application-routes) |
| Membuat node dengan pengaturan yang cocok | **Anda** | [3](#3-pengaturan-node-di-panel-sinkron-dengan-route) |
| Pengaturan zone, WAF, Access | **Anda** | [4](#4-pengaturan-zone-yang-direkomendasikan), [5](#5-cloudflare-access-untuk-area-admin-disarankan) |
| Memeriksa jalur publik | otomatis (`verify`) | [6](#6-verifikasi) |

## 0. Zone harus Active

1. Tambahkan domain ke Cloudflare (*Add a domain*). Anda mendapat dua nameserver `*.ns.cloudflare.com`.
2. Di **registrar** domain, ganti **semua** nameserver dengan dua itu.
3. Tunggu zone berstatus **Active**. Cek dari shell: `nslookup -type=NS contoh.com 1.1.1.1` harus menampilkan dua nameserver Cloudflare.

Selama zone *Pending*, hostname di tunnel tampak benar tetapi browser menampilkan `DNS_PROBE_POSSIBLE` atau NXDOMAIN. Ini pernah terjadi pada stack pendahulu repositori ini.

Gunakan hostname satu tingkat (`panel.contoh.com`, `wings.contoh.com`). Subdomain bertingkat (`a.b.contoh.com`) memerlukan Advanced Certificate.

## 1. Buat *named tunnel* (bukan quick tunnel)

*Quick tunnel* (`*.trycloudflare.com`) berganti hostname tiap restart. URL Panel dan node Wings tertulis di konfigurasi, jadi itu merusak CSRF, autentikasi node, dan CORS. Pakai tunnel bernama:

1. *Tunnels → Create a tunnel → Cloudflared*, beri nama (misalnya `pterodactyl`).
2. Pada pilihan konektor pilih **Docker**. Dashboard menampilkan perintah `docker run ... --token XXXX`. **Salin hanya nilai token** (atau tempel seluruh baris: `./ptero tunnel set-token` memotongnya sendiri). Jangan menjalankan perintah itu; konektornya dijalankan oleh `compose.yml`.
3. Di server: `./ptero tunnel set-token`, lalu `./ptero up` (atau `./ptero setup` pada instalasi pertama).
4. Tunnel di dashboard berstatus **Healthy** bila konektor tersambung. Secara lokal, `./ptero status` harus menampilkan `cloudflared healthy`.

Server perlu koneksi **keluar** ke Cloudflare pada port 7844 (TCP dan UDP). `./ptero preflight` memeriksa TCP 7844.

## 2. Dua route (Published application routes)

`./ptero tunnel info` mencetak nilai persisnya dari konfigurasi Anda. Pada tunnel → tab **Routes** → *Add route* → *Published application*:

| Subdomain + domain | Service URL (**wajib dengan skema**) |
|---|---|
| `PANEL_FQDN` | `http://127.0.0.1:8081` (nilai `PANEL_BIND_PORT`) |
| `WINGS_FQDN` | `http://127.0.0.1:443` (nilai `WINGS_API_PORT`) |

- Service URL tanpa `http://` ditolak form dengan `Invalid service URL`.
- Skemanya `http`, bukan `https`: TLS berakhir di Cloudflare, dan origin hanya mendengar di loopback.
- Origin memakai `127.0.0.1` karena konektor berjalan dengan jaringan host.
- Dengan `WINGS_MODE=container` origin-nya sama (`http://127.0.0.1:WINGS_API_PORT`): "host" bagi konektor adalah VM Docker Desktop, dan di situlah port API container Wings dipublikasikan. Wings systemd di distro WSL tidak terjangkau dari sana (`502`).
- WebSocket (konsol server) bekerja tanpa pengaturan tambahan pada route HTTP.
- Port origin Wings harus sama dengan `api.port` di config Wings. Panel menulis `api.port` dari **Daemon Port** node dan menimpanya setiap node disimpan; `wings configure` menambalnya ke `WINGS_API_PORT`. Bila port tidak cocok, Anda mendapat `502` di edge.

Cloudflare membuat CNAME ber-proxy (awan oranye) otomatis untuk kedua hostname.

## 3. Pengaturan node di Panel (sinkron dengan route)

*Admin → Nodes → Create*:

| Kolom | Nilai |
|---|---|
| **FQDN** | `WINGS_FQDN` |
| **Communicate over SSL** | *Use SSL* |
| **Behind Proxy** | *Behind Proxy* |
| **Daemon Port** | `443` (sama dengan `WINGS_API_PORT`) |
| SFTP port | `2022` |

Dengan *Behind Proxy*, Panel menulis `api.ssl.enabled: false` dan Wings melayani HTTP polos untuk tunnel. Browser tetap memakai `https://WINGS_FQDN`. Node yang disimpan sebagai *Use SSL* tanpa *Behind Proxy* membuat Wings gagal start dengan error HTTPS, dan `./ptero wings configure` menolak config-nya.

## 4. Pengaturan zone yang direkomendasikan

- **SSL/TLS.** Aktifkan *Always Use HTTPS* dan *Minimum TLS 1.2*; aktifkan HSTS setelah Anda yakin. Mode enkripsi zone tidak memengaruhi hop tunnel ke origin (HTTP di loopback).
- **Cache Rule (opsional, mengurangi beban).** `starts_with(http.request.uri.path, "/assets/")` pada hostname Panel → *Eligible for cache*. Jangan men-cache HTML atau `/api/`.
- **WAF dan rate limit untuk login.** Aturan pada `/auth/login` di hostname Panel (misalnya 10 permintaan per 10 detik per IP) dan **Bot Fight Mode**. Uji dulu dengan aksi *Log*.
- **Jangan** menempatkan Cloudflare Access, Managed Challenge, atau Bot Fight agresif di depan `WINGS_FQDN`. Panel memanggilnya server ke server dengan JWT, dan konsol browser memakai WebSocket; keduanya tidak bisa menyelesaikan login atau tantangan interaktif.
- **Batas Cloudflare.** Badan permintaan maksimum **100 MB** (Free/Pro) untuk hostname ber-proxy. Ini memengaruhi unggahan file besar lewat browser.

## 5. Cloudflare Access untuk area admin (disarankan)

Access tidak dapat dibuat dari server ini. Di *Access → Applications → Add → Self-hosted*: destination `PANEL_FQDN` dengan path `admin`, kebijakan **Allow** untuk email Anda (atau IdP), durasi sesi sesuai kebutuhan.

Pegangan dari dokumentasi Cloudflare:

- Akses ditolak secara bawaan bagi yang tidak cocok kebijakan Allow.
- Jangan memakai *Bypass* untuk `/admin`: tidak ada kontrol dan tidak dicatat.
- Skrip atau otomasi memakai kebijakan *Service Auth* dengan *service token*, bukan Allow.

**Belum diverifikasi:** path admin persis di UI Panel 2.0, dan apakah halaman admin memanggil `/api/*` dari browser. Buka admin lewat jendela privat dan lihat tab Network sebelum membatasi path lain. Jangan menutup `/api/` ke publik sampai Anda yakin klien API Anda (integrasi) tidak memerlukannya.

## 6. Verifikasi

```bash
./ptero verify
```

| Hasil | Arti |
|---|---|
| DNS tidak resolve | zone belum Active, atau route atau CNAME belum ada |
| Panel `200`, Wings `401` | normal: Wings menjawab dan meminta autentikasi |
| `530`, `1033`, atau `502` dari Cloudflare | konektor tidak tersambung, atau origin route salah (`./ptero tunnel info`), atau Wings belum berjalan |
| Wings `403` atau `404` | juga normal bila Anda memasang aturan allow-list WAF di depan Wings |

Sebelum Wings terpasang, baris Wings pada `verify` gagal dengan `502`. Itu wajar sampai [Instalasi lengkap](installation.md#langkah-8-buat-node-dan-pasang-wings) selesai.

## Trafik game tidak bisa lewat tunnel ini

Tunnel di sini membawa **HTTP(S) dan WebSocket** untuk dua hostname. Itu **bukan** proxy TCP/UDP umum:

- Rute berdasarkan path URL tidak ada untuk protokol game; path hanya konsep HTTP.
- Tunnel memang bisa membawa TCP mentah ke aplikasi privat, tetapi setiap klien harus menjalankan `cloudflared access` atau WARP. Itu tidak cocok untuk pemain publik.
- DNS ber-proxy (awan oranye) hanya HTTP(S).
- Cloudflare Spectrum memproksi TCP/UDP, tetapi menurut dokumentasi Cloudflare tersedia di paket berbayar, dan aplikasi TCP/UDP kustom memerlukan Enterprise dengan add-on Spectrum (cek halaman *Protocols per plan* untuk paket Anda).
- Record SRV (`_minecraft._tcp.nama`) hanya **memetakan nama dan port**; ia bukan transport. Berguna sebagai nama yang rapi di depan relay yang memang meneruskan TCP/UDP.

**Apa yang dilakukan repositori ini untuk game** (hanya bila `GAMES_ENABLED=yes`): satu `mc-router` di port 25565 pada VPS Anda yang memilih server dari nama host, dengan **satu record DNS wildcard *DNS only*** yang Anda buat sekali (`./ptero games dns`), dan firewall yang membuka hanya SSH dan port itu. Itu bukan Cloudflare yang membawa trafik game: Cloudflare di sini hanya memegang DNS untuk nama game, dan IP server tampak di DNS. Rinciannya: [Server Minecraft](games.md). Bila Anda tidak mau IP terlihat, pilihannya adalah relay TCP/UDP (layanan tunnel game pihak ketiga, VPS relay seperti frp) atau Spectrum bila paket Anda mendukungnya. Keputusan itu terpisah dan tidak diotomatisasi di sini.

## Rotasi dan pencabutan

Token tunnel bocor? Di dashboard: tunnel → *Refresh token*, lalu `./ptero tunnel set-token` dan `./ptero up`. Hapus tunnel di dashboard untuk mematikan jalur publik sepenuhnya. Prosedur rotasi rahasia lain: [Keamanan](security.md#respons-insiden-dan-rotasi-rahasia).

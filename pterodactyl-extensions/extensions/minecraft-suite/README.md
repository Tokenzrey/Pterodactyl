# Minecraft Suite

Pantau kesehatan server Minecraft dari Panel: **TPS** (1, 5, 15 menit), **MSPT**, dan **uptime**. Datanya dibaca lewat **RCON** (soket TCP langsung dari PHP); tidak ada dependensi tambahan.

- Halaman **Health** di navigasi server, dan widget "TPS 19.98 · Healthy" di atas konsol.
- Tiap nilai TPS punya kata di sampingnya (Healthy dari 19, Lagging dari 15, Struggling di bawah), bukan hanya warna.
- Nilai yang tidak diketahui ditampilkan **N/A**, bukan angka karangan.
- Diperbarui tiap 10 detik (bisa diatur 5 sampai 60), berhenti saat tab tidak terlihat.
- Komponen `PlayerAvatars` (avatar Crafatar untuk daftar UUID) tersedia untuk dipakai, tetapi **belum dipasang di halaman mana pun**: extension ini tidak membaca daftar pemain. Daftar pemain ada di extension `player-manager`.

## Prasyarat di server Minecraft

| Kebutuhan | Keterangan |
|---|---|
| RCON aktif | Di `server.properties`: `enable-rcon=true`, `rcon.port=<port>`, `rcon.password=<kata sandi>`. Port RCON **bukan** port game. Mulai ulang server setelah mengubahnya. |
| Perintah TPS | Plugin **spark** (`spark tps`, bawaan) atau Paper/Purpur (`tps`). Server vanilla tanpa keduanya menampilkan N/A. |
| Panel bisa menjangkau port RCON | Bila Panel dan server satu mesin, pakai `127.0.0.1`. |

Format yang dikenali: `TPS (1m/5m/15m): 19.98/19.99/20.00. MSPT: 1.2` (spark), `TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0` (Paper), dan bentuk lima nilai `TPS from last 5s, 10s, 1m, 5m, 15m: ...`. Kode warna Minecraft dan tanda `*` Paper diabaikan. Jawaban lain dibaca sebagai "tidak dikenali".

## Pengaturan (per server)

Admin → Servers → pilih server → tab **Details** → bagian **Minecraft Suite: RCON**. Hanya administrator root yang melihatnya.

| Bidang | Arti |
|---|---|
| RCON host / port | Seperti di Player Manager. Diisi sendiri-sendiri per extension; keduanya berdiri sendiri. |
| RCON password | Disimpan terenkripsi; hanya topeng yang tampil. Biarkan apa adanya untuk mempertahankan yang tersimpan. |
| TPS command | Bawaan `spark tps`. Isi `tps` untuk Paper/Purpur. |
| Refresh every | 5000 sampai 60000 ms. Bawaan 10000. |
| Cache answers for | 0 sampai 30 detik. Bawaan 3. |

## Izin subuser

| Izin | Mengizinkan |
|---|---|
| `ext.minecraft-suite.read` | Melihat halaman Health dan widget TPS |

Pemilik server dan administrator root otomatis lolos.

## Perilaku yang perlu diketahui

- **Versi server selalu N/A.** RCON tidak punya sumber yang dapat diandalkan untuk itu, jadi tidak ditebak.
- **Uptime** diambil dari Wings dan dibaca sebagai milidetik (mengikuti contoh respons Panel). Bila Wings tidak terjangkau, uptime kosong tetapi TPS tetap dicoba. Nilai `0` dari Wings berarti "belum diukur" dan ditampilkan N/A.
- **Server mati** (menurut Wings): semua nilai N/A dan RCON tidak dipanggil.
- **TPS di atas 20** dipotong ke 20; nilai negatif jadi N/A.
- **Galat RCON** ditampilkan dengan kalimat tetap; teks asli server tidak pernah ditampilkan.
- **Batas laju** dihitung per pengguna, bukan per pengguna per server: 30 permintaan per menit.

## Keamanan

- Host RCON hanya dari pengaturan yang diisi administrator root.
- **RCON tidak mendukung TLS.** Jalankan Panel dan server di satu mesin atau lewat jaringan pribadi/VPN.
- Kata sandi tidak ada di respons API, log, atau pesan galat. Jawaban mentah server tidak dicatat.
- Baris yang bukan di awal baris (mis. pemain mengetik kalimat berformat TPS di chat) tidak dibaca sebagai keluaran TPS.

## Yang belum diuji

Semua uji memakai RCON tiruan; tidak ada server Minecraft, Wings, spark, atau Crafatar sungguhan.

| Belum diuji | Risiko |
|---|---|
| Format keluaran `spark tps` dan `/tps` nyata | Parser mengikuti contoh dari spesifikasi, ditambah toleransi warna dan lima nilai. Versi spark/Paper yang mengubah teksnya akan terbaca "tidak dikenali" (N/A, bukan data salah). Konfirmasikan bentuk aslinya saat pemakaian pertama. |
| Satuan uptime Wings | Diasumsikan milidetik; belum dibandingkan dengan Wings sungguhan. |
| Tampilan di peramban sungguhan | Diuji dengan jsdom dan host SDK. |

## Pengembangan

Dari akar repositori (di WSL):

```
tools/pest.sh minecraft-suite     # tes PHP terhadap Panel nyata
tools/build.sh minecraft-suite    # typecheck, tes frontend, build
tools/pack.sh minecraft-suite     # doctor + dist/minecraft-suite-1.0.0.pteroext
```

Spesifikasi: [plan/08](../../plan/08-spec-minecraft-suite.md). Keputusan desain: [plan/06](../../plan/06-grill-player-minecraft.md). Model ancaman: [plan/09](../../plan/09-threat-model-player-minecraft.md).

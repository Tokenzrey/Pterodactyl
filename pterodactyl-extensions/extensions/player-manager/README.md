# Player Manager

Lihat siapa yang sedang online di server Minecraft, dan kick, ban, beri atau cabut OP dari Panel, tanpa membuka konsol. Panel berbicara dengan server lewat **RCON** (soket TCP langsung dari PHP); tidak ada dependensi tambahan.

- Halaman **Players** di navigasi server, dan widget "X / Y players online" di atas konsol.
- Aksi: kick, ban, OP, de-OP. Setiap aksi meminta konfirmasi dan punya izin subuser sendiri.
- Daftar diperbarui tiap 10 detik (bisa diatur 5 sampai 60), berhenti saat tab tidak terlihat.
- Avatar dari Crafatar untuk pemain yang punya UUID.

## Prasyarat di server Minecraft

| Kebutuhan | Keterangan |
|---|---|
| RCON aktif | Di `server.properties`: `enable-rcon=true`, `rcon.port=<port>`, `rcon.password=<kata sandi>`. Port RCON **bukan** port game. Mulai ulang server setelah mengubahnya. |
| Panel bisa menjangkau port RCON | Bila Panel dan server satu mesin, pakai `127.0.0.1`. Bila tidak, pakai alamat yang terjangkau dari Panel. |
| Data lengkap (UUID, ping, status OP) | Butuh **plugin** yang menjawab perintah daftar dengan JSON (bawaan: `playermanager:players`). Plugin itu tidak disertakan di sini. Tanpa plugin, perintah `list` biasa hanya memberi nama: UUID, ping, dan status OP kosong. |

Bentuk JSON yang dikenali (semua field selain `online_count` boleh hilang):

```json
{"online_count": 2, "max_count": 20, "players": [{"name": "Steve", "uuid": "069a79f4-44e9-4726-a5be-fca90e38aaf5", "ping": 45, "is_op": true}]}
```

## Pengaturan (per server)

Admin → Servers → pilih server → tab **Details** → bagian **Player Manager: RCON**. Hanya administrator root yang melihatnya.

| Bidang | Arti |
|---|---|
| RCON host | Alamat IPv4, IPv6, atau nama host. Bukan URL dan bukan alamat dengan jalur. |
| RCON port | `rcon.port` dari `server.properties`. 1 sampai 65535. |
| RCON password | `rcon.password`. Disimpan terenkripsi; tidak pernah ditampilkan lagi (hanya topeng). Biarkan apa adanya untuk mempertahankan yang tersimpan. Tidak bisa dikosongkan dari form; ganti dengan yang baru bila perlu. |
| Player list command | Bawaan `playermanager:players`. Isi `list` bila tidak ada plugin. |
| Refresh every | 5000 sampai 60000 ms. Bawaan 10000. |
| Cache answers for | 0 sampai 30 detik. Bawaan 3. Beberapa penonton berbagi satu panggilan RCON dalam jendela ini. |

## Izin subuser

Muncul di editor izin subuser sebagai grup `ext.player-manager`. Pemilik server dan administrator root otomatis lolos semua.

| Izin | Mengizinkan |
|---|---|
| `ext.player-manager.read` | Melihat halaman Players dan widget jumlah pemain |
| `ext.player-manager.kick` | Kick |
| `ext.player-manager.ban` | Ban |
| `ext.player-manager.op` | Memberi OP |
| `ext.player-manager.deop` | Mencabut OP |

## Perilaku yang perlu diketahui

- **Kick, ban, OP dan de-OP hanya mengirim perintah.** Panel menampilkan "Kick command sent for Steve." karena RCON menjawab sukses juga bila pemain sudah keluar. Jawaban server tidak diteruskan.
- **Un-ban tidak ada di sini.** Pakai `pardon <nama>` di konsol.
- **Server mati** (menurut Wings): daftar kosong dan RCON tidak dipanggil. Bila Wings tidak terjangkau, statusnya dianggap tidak diketahui dan RCON tetap dicoba.
- **Galat RCON** ditampilkan dengan kalimat tetap (RCON belum diatur, server tidak terjangkau, kata sandi ditolak, tidak menjawab, jawaban tak terduga). Teks asli dari server tidak pernah ditampilkan.
- **Batas laju** dihitung per pengguna, bukan per pengguna per server: 30 permintaan baca per menit dan 10 aksi per menit di seluruh server yang dibuka pengguna itu.

## Keamanan

- Host RCON hanya dari pengaturan yang diisi administrator root; tidak pernah dari input pengguna.
- Nama pemain divalidasi (`3 sampai 16 huruf, angka, atau garis bawah`) sebelum masuk perintah RCON. Alasan kick/ban dibatasi 256 karakter ASCII yang dapat dicetak.
- **RCON tidak mendukung TLS.** Kata sandi lewat jaringan antara Panel dan server tanpa enkripsi. Jalankan keduanya di satu mesin (`127.0.0.1`) atau lewat jaringan pribadi/VPN.
- Avatar dimuat browser pengguna dari `crafatar.com`; UUID pemain terkirim ke layanan itu. UUID bukan rahasia, tetapi ini pihak ketiga.
- Kata sandi tidak ada di respons API, log, atau pesan galat.

## Yang belum diuji

Semua uji memakai RCON tiruan; tidak ada server Minecraft, Wings, atau Crafatar sungguhan di lingkungan uji.

| Belum diuji | Risiko |
|---|---|
| RCON ke server Minecraft sungguhan | Protokol diuji lewat tiruan dan dengan byte yang ditulis tangan. Bentuk jawaban nyata (mis. teks `list` versi tertentu, paket besar) perlu Anda konfirmasi saat pemakaian pertama. |
| Plugin pemain | Format JSON diuji dari contoh, bukan dari plugin nyata. |
| Tampilan di peramban sungguhan | Antarmuka diuji dengan jsdom dan host SDK, bukan peramban. |
| Pembatasan "per server" | Lihat bagian perilaku di atas. |

## Pengembangan

Dari akar repositori (di WSL):

```
tools/pest.sh player-manager     # tes PHP terhadap Panel nyata
tools/build.sh player-manager    # typecheck, tes frontend, build
tools/pack.sh player-manager     # doctor + dist/player-manager-1.0.0.pteroext
```

Spesifikasi: [plan/07](../../plan/07-spec-player-manager.md). Keputusan desain: [plan/06](../../plan/06-grill-player-minecraft.md). Model ancaman: [plan/09](../../plan/09-threat-model-player-minecraft.md).

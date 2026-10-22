# Subdomain Manager

Record DNS di Cloudflare untuk server game, dibuat dari form server admin lewat job antrean dan dibersihkan saat server dihapus. Ada dua mode, dipilih di pengaturan (**Mode**):

- **Routed** (`mode = routed`): satu port publik, 25565, lewat mc-router. Nama server diambil dari slug nama server (sama dengan `games sync`), label tidak bisa diedit, dan tidak ada record A per server. Form dan daftar menampilkan apakah nama itu dirutekan (**Will be routed**) atau tidak, beserta alasannya. Prasyarat: record wildcard `*.mc.<domain>` sudah ada di Cloudflare (tidak diperiksa oleh extension).
- **Per-port** (`mode = per_port`): setiap server memakai port alokasi utamanya sendiri (lihat [README proyek](../../README.md#beberapa-server-game-satu-port-per-server)). Setting **SRV port** dipakai hanya di mode ini: `0` (bawaan) memakai port alokasi, angka lain mengarahkan semua nama ke port itu.

Mengubah mode memperbarui semua record: record SRV yang portnya berbeda diganti. Perubahan ini dijalankan oleh `subdomain-manager:reconcile` (tiap 5 menit) atau langsung dengan `subdomain-manager:resync`. Record SRV yang sudah benar tidak menyebabkan panggilan Cloudflare.

Ganti nama server di Panel (routed mode): label ikut berubah dan DNS diperbarui. Nama yang menghasilkan slug kosong, atau slug yang sudah dipakai server Minecraft lain, ditolak sebelum disimpan.

API admin: `GET /api/admin/extensions/subdomain-manager/{config,availability}`. Perintah: `subdomain-manager:reconcile` (terjadwal tiap 5 menit), `subdomain-manager:resync`.

Pengaturan, keamanan, pemasangan, dan hasil uji: lihat [README proyek](../../README.md). Spesifikasi: [plan/02](../../plan/02-spec-subdomain-manager.md), perubahan mode routed: [plan/19](../../plan/19-spec-subdomain-routed-mode.md).

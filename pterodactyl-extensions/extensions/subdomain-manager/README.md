# Subdomain Manager

Record A (+ SRV Minecraft) di Cloudflare untuk server game, dibuat dari form server admin lewat job antrean dan dibersihkan saat server dihapus. SRV port bawaan `0`: setiap server memakai port alokasi utamanya sendiri (lihat [README proyek](../../README.md#beberapa-server-game-satu-port-per-server)). API admin: `GET /api/admin/extensions/subdomain-manager/{config,availability}`. Perintah: `subdomain-manager:reconcile` (terjadwal tiap 5 menit).

Pengaturan, keamanan, pemasangan, dan hasil uji: lihat [README proyek](../../README.md). Spesifikasi: [plan/02](../../plan/02-spec-subdomain-manager.md).

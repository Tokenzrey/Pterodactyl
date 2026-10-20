# Extension Pterodactyl Panel 2.0: OAuth Login dan Subdomain Manager

Dua extension untuk Panel `v2.0.0-beta.2` (SDK `2.0.0-beta.6`), dibangun dan diuji di lingkungan terpisah dari repositori deploy.

| Extension | Fungsi | Paket |
|---|---|---|
| [`oauth-login`](extensions/oauth-login) | Masuk dengan Discord, GitHub, atau Google di bawah form login. Akun bisa dihubungkan dan diputus dari halaman **Connected accounts**. Tidak mengganti kata sandi/2FA bawaan. | `dist/oauth-login-1.0.0.pteroext` |
| [`subdomain-manager`](extensions/subdomain-manager) | Membuat dan menghapus record A (+ SRV `_minecraft._tcp`) di Cloudflare untuk server game, dari form server admin. Halaman admin **Subdomains** menampilkan status, uji koneksi, dan tombol coba ulang/hapus. | `dist/subdomain-manager-1.0.0.pteroext` |

Dokumen perencanaan: [`plan/`](plan) (koreksi terhadap spesifikasi awal, spesifikasi, model ancaman, rencana).

## Keputusan desain yang penting

- **OAuth**: `state` (256 bit, terikat sesi, sekali pakai, 10 menit, dan diblokir lagi di cache agar dua permintaan paralel tak lolos bersamaan), PKCE S256 untuk GitHub/Google, `redirect_uri` hanya dari `APP_URL`, hanya email **terverifikasi oleh penyedia**, kebijakan admin/2FA diperiksa **sebelum** tautan dibuat, tabel identitas unik `(provider, id)`. Tanpa token disimpan.
- **Menautkan akun** (di luar spesifikasi 01): hanya untuk pengguna yang sudah masuk. Alur mengingat siapa yang memulainya; saat callback, pengguna yang masuk harus sama, tidak ada sesi baru, tidak ada akun baru. Kebijakan admin/2FA tidak berlaku untuk menautkan, hanya untuk masuk.
- **Subdomain**: simpan niat di DB, panggil Cloudflare hanya dari job antrean setelah commit (Cloudflare mati tidak menggagalkan simpan/hapus server); idempoten (ID record disimpan setelah tiap panggilan); tidak pernah menimpa record orang lain (konflik = gagal); hapus **hanya** berdasarkan ID tersimpan; reconcile tiap 5 menit.
- **Tampilan**: komponen SDK Panel dipakai (`Select`, `Button`, `Badge`, `Table`, `Card`), agar kontrol terlihat dan terasa seperti bagian Panel. Pemberitahuan memakai `Notice` sendiri dengan bingkai 1 px dan latar tipis, bukan garis kiri berwarna. Teks sekunder memakai `text-foreground/80` karena `muted-foreground` di tema gelap Panel kontrasnya di bawah 4,5:1.
- Koreksi atas spesifikasi awal (rute `client.php` butuh login → dipakai rute web; slot yang benar `auth.login.form.after`; `Fields` tak punya `delete()` → listener `OperationCompleted`; dan lainnya): [plan/00](plan/00-grill-dan-keputusan.md).

## Memasang

> Belum pernah dipasang di Panel produksi Anda. Pasang di Panel uji dulu.

1. Daftarkan aplikasi OAuth Anda sendiri. Redirect URI: `https://PANEL/extensions/oauth-login/callback/{discord|github|google}`.
2. Salin `dist/*.pteroext` ke Panel lalu `php artisan p:extension:install <berkas> --enable` (atau lewat halaman admin Extensions).
3. Admin → Extensions → pengaturan masing-masing:
   - **OAuth Login**: centang penyedia, isi client ID/secret, putuskan `allow_registration` (bawaan mati), `allow_admin_login` (bawaan mati), kebijakan 2FA (bawaan: tolak akun 2FA).
   - **Subdomain Manager**: token API Cloudflare dengan izin **Zone → DNS → Edit** terbatas ke zona Anda, daftar `domain:zone_id`, alamat IPv4 tujuan, SRV, TTL. Halaman **Subdomains** di menu admin memperlihatkan apakah pengaturan sudah lengkap dan bisa menguji koneksi ke tiap domain.
4. Jalankan antrean dan scheduler Panel (`QUEUE_WORKER_ENABLED`/`SCHEDULER_ENABLED`) agar job DNS dan `subdomain-manager:reconcile` berjalan.
5. Panel di belakang Cloudflare Tunnel: set `TRUSTED_PROXIES` benar, jika tidak semua pengunjung berbagi satu batas laju 20/menit pada rute OAuth.
6. Nonaktifkan pemasangan lewat URL (`PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED`) bila tidak dipakai.

## Membangun dan menguji (lingkungan dev)

Lingkungan berat ada di `~/pterodactyl-extensions-env` (WSL ext4): checkout Panel `v2.0.0-beta.2`, Node, `.env` uji. Lihat [`tools/`](tools).

| Perintah | Untuk |
|---|---|
| `tools/setup.sh` | cek lingkungan, siapkan MariaDB uji (`ptero-ext-dev-db`) |
| `tools/pest.sh <id> [--filter=...]` | test PHP (Pest, di image Panel yang dipatok; `FAST=1` lewati `migrate:fresh`) |
| `tools/build.sh <id>` | salin ke Panel, `npm install`, typecheck, Vitest, build, lalu `check-classes.py` |
| `tools/check-classes.py <dir> <css>` | gagal bila kelas ber-prefix (`olg:`, `sdm:`) yang ditulis di sumber tidak terbentuk di CSS hasil build |
| `tools/pack.sh <id>` | build + `p:extension:doctor` + `.pteroext` bersih di `dist/` |
| `tools/e2e.sh` | Panel sementara di jaringan **internal** (tanpa jalan keluar), pasang kedua paket, uji lewat HTTP nyata, bersihkan sendiri |
| `tools/db.sh down` | hapus hanya `ptero-ext-dev-*` |

Urutan verifikasi penuh: `setup.sh`, `pest.sh` untuk kedua suite (tanpa `FAST`), `build.sh` untuk kedua extension, `pack.sh` untuk kedua extension, lalu `e2e.sh`.

## Hasil verifikasi (2026-10-20, jalur `D:\Documents\code\pterodactyl\pterodactyl-extensions`)

| Pemeriksaan | Hasil |
|---|---|
| Pest `oauth-login` (dari `migrate:fresh`) | 345 lulus, 1141 assertion |
| Pest `subdomain-manager` (dari `migrate:fresh`) | 349 lulus, 1052 assertion |
| Vitest `oauth-login` / `subdomain-manager` | 61 / 71 lulus; typecheck dan build bersih |
| `check-classes.py` | 57 kelas `olg:` dan 67 kelas `sdm:`, 0 hilang |
| `p:extension:doctor` pada paket bersih | bersih untuk keduanya |
| E2E di Panel nyata (image dipatok) | 62 lulus, 0 gagal |
| Detector desain (impeccable) pada sumber client | bersih |
| Uji mutasi (7 baris kritis dirusak satu per satu) | 7/7 terbunuh oleh test (putaran sebelumnya) |
| Pemindaian pola berbahaya dan rahasia | bersih |

Tampilan diperiksa dengan screenshot: komponen asli dirender di Edge headless memakai CSS Panel (hasil compile Tailwind Panel), dengan data fixture. Harness ini ada di `~/pterodactyl-extensions-env/harness` dan tidak masuk repositori. Edge tidak bisa dibuat lebih sempit dari sekitar 496 px, jadi tampilan 390 px dicek dengan membatasi lebar `#root`.

## Jejak kebutuhan → test

| Kebutuhan | Test |
|---|---|
| OAuth FR-O1..O4, AC-O1..O4, O17, O18 (rute, redirect, PKCE, 404, Host, throttle) | `oauth-login/tests/Integration/OAuthRedirectTest.php`, `Unit/FlowTest.php`, `Unit/ProviderTest.php` |
| FR-O5..O7, AC-O5..O7, O15, O16 (state, replay, kedaluwarsa, issuer, kegagalan penyedia) | `OAuthCallbackTest.php`, `Unit/FlowTest.php`, `Unit/ProviderClientTest.php` |
| FR-O7, AC-O10, EC-O1, EC-O6 (email terverifikasi) | `Unit/ProfileParserTest.php`, `OAuthCallbackTest.php` |
| FR-O8..O11, AC-O8, O9, O11..O14, EC-O2..O4, EC-O9 (akun, tautan, kebijakan, registrasi, balapan) | `OAuthCallbackTest.php`, `AccountResolverTest.php`, `Unit/PolicyTest.php`, `Unit/UsernamesTest.php` |
| FR-O12, FR-O13, NFR-O3 (redirect ke `/`, kode galat tetap, tanpa rahasia di log) | `OAuthCallbackTest.php` |
| NFR-O2, O4, FR-O1, EC-O10, AC-O19 (rahasia terenkripsi, topeng, tamu hanya `enabled_providers`) | `SettingsTest.php`, `src/client/*.spec.tsx` |
| Tautkan akun (di luar spesifikasi 01) | `LinkAccountTest.php`, `Unit/FlowTest.php` (pengguna pemilik alur), `AccountsApiTest.php` |
| Connected accounts UI (di luar spesifikasi 01) | `src/client/screens/ConnectedAccounts.spec.tsx`, `ResultBanner` di `ErrorBanner.spec.tsx` |
| Subdomain FR-S1..S3, AC-S1, S5, S6, S9..S11, EC-S1 (form, validasi, antre setelah commit) | `subdomain-manager/tests/Integration/SubdomainFieldsTest.php`, `Unit/LabelsTest.php`, `Unit/DomainsTest.php` |
| FR-S4..S8, AC-S2..S4, S7, S8, S14, EC-S2..S10 (sinkron idempoten, konflik, ganti nama, hapus) | `RecordSyncerTest.php`, `SubdomainFieldsTest.php` |
| NFR-S3..S5, AC-S15, FR-S12 (klien Cloudflare, error disanitasi, hapus lewat ID) | `Unit/CloudflareClientTest.php`, `Unit/PayloadsTest.php` |
| FR-S8, S9, AC-S16 (job, reconcile, jadwal) | `SyncRecordJobTest.php` |
| FR-S10, AC-S12, S13 (API admin, akses, tanpa token/zone) | `AdminRoutesTest.php`, `SettingsTest.php`, `SubdomainFieldsTest.php` |
| FR-S11, AC-S17 (UI: debounce 500 ms, pembatalan, status) | `src/client/SubdomainInput.spec.tsx` |
| Halaman Subdomains (di luar spesifikasi 02): ringkasan, uji koneksi, daftar, filter, cari, coba ulang, hapus | `subdomain-manager/tests/Integration/RecordsApiTest.php`, `src/client/screens/Subdomains.spec.tsx` |

## Batas pengujian (jujur)

Tidak diuji: login nyata ke Discord/GitHub/Google dan Cloudflare nyata (butuh akun dan token Anda; bentuk respons mengikuti dokumentasi resmi, **konfirmasi pada percobaan pertama**); Wings dan server game nyata (Fields diuji lewat Admin API Panel dengan Wings tiruan); Panel di belakang Cloudflare Tunnel nyata; beban dan serangan nyata. Tampilan diperiksa dengan screenshot satu kali per pass, bukan regresi visual otomatis. "Bebas bug" tidak diklaim.

## Batas yang diketahui

- Mengganti `target_ipv4`, TTL, atau port SRV **tidak** memperbarui record yang sudah ada; hapus lalu simpan ulang label (atau ubah label) untuk membuat ulang.
- Record yang dibuat Cloudflare tetapi ID-nya belum sempat tersimpan (proses mati tepat di antaranya) tampak sebagai konflik; hapus manual di Cloudflare.
- `successful` penghapusan lewat antrean `sync` tidak punya retry (antrean nyata punya 5 percobaan); `reconcile` menutup celahnya.
- Penautan akun lewat email mengandalkan verifikasi email di penyedia; admin dan akun 2FA ditolak secara bawaan karena alasan itu.
- **Memutus akun bisa mengunci pengguna.** Pengguna yang dibuat lewat pendaftaran OAuth punya kata sandi acak. Jika ia belum pernah menetapkan kata sandi, memutus akun berarti tidak bisa masuk lagi. Teks konfirmasi memperingatkan ini, tetapi Panel tidak menyimpan tanda "kata sandi sudah ditetapkan", jadi tidak bisa dicegah otomatis.
- Form pengaturan admin Subdomain menampilkan daftar `domain:zone_id` apa adanya (zone id bukan rahasia); token selalu topeng.

## Temuan review adversarial

Saboteur, New Hire, Security Auditor atas kedua extension. Tidak ada temuan BLOCK. Catatan yang dicatat/ditangani: balapan state paralel (ditutup dengan kunci cache atomik), email di log (dilarang dan diuji), pembatas laju bergantung `TRUSTED_PROXIES` (didokumentasikan), pembaruan record tak otomatis saat pengaturan berubah (didokumentasikan), kebocoran token lewat pesan galat Cloudflare (disanitasi dan diuji). Putaran UI menambahkan satu catatan: risiko mengunci pengguna saat memutus akun (lihat di atas). Verdict: **CONCERNS** (hanya batas yang didokumentasikan di atas).

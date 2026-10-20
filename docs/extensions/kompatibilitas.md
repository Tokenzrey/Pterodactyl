# Kompatibilitas: dokumen upstream versus Panel beta.2 yang dikunci

> **Jenis:** Referensi + keputusan · **Per:** 2026-10-20 · **Dasar:** dokumen extension di branch `v2` repo dokumentasi (commit `d34763bd`, 2026-10-19) dan kode tag `v2.0.0-beta.2` (commit `ea742d33`, 2026-10-14) · **Kembali ke:** [indeks extension](README.md)

Dokumen upstream extension (docs.pterodactyl.io/v2) ditulis **lebih baru** daripada Panel yang dikunci repositori ini. Beberapa fitur yang didokumentasikan belum ada di tag `v2.0.0-beta.2`, dan beberapa fitur yang ada di kode belum didokumentasikan. Halaman ini mencatat setiap selisih, dampaknya ke repositori ini, dan apa yang belum diperiksa.

## Versi yang dibandingkan

| Komponen | Nilai | Sumber |
|---|---|---|
| Panel (yang dikunci repo) | `v2.0.0-beta.2`, tag dibuat 2026-10-14 | `pterodactyl/panel`, commit `ea742d33` |
| Branch rilis Panel | `release/v2.0.0-beta.2`, **1 commit di depan** tag | perbandingan GitHub |
| SDK yang dikirim | `@pterodactyl/sdk` **2.0.0-beta.6** | `packages/sdk/package.json` di tag |
| `sdk_version` runtime | `2.0.0-beta.6` | `config/extensions.php` di tag |
| `app.version` default | `canary` (dipetakan ke `2.0.0-dev` untuk `requires.panel`) | `config/app.php` dan `config/extensions.php` di tag |
| Dokumen extension | branch `v2`, commit `d34763bd`, 2026-10-19 | `pterodactyl/documentation` |

Catatan: branch rilis satu commit lebih baru dari tag. Kode yang saya baca berasal dari **tag** (commit `ea742d33`), jadi itulah yang dibandingkan.

## Fitur yang didokumentasikan tetapi belum ada di beta.2

| Fitur (dokumen) | Di beta.2 | Dampak |
|---|---|---|
| `ui.components` (daftar penggantian komponen) | ❌ validator tidak mengenal kunci ini; hanya `ui.views` | extension yang memakai `ui.components` kemungkinan diabaikan **tanpa error**. Belum diuji |
| `components.replace(name, replacement)` di `setup` | ❌ tidak ada di SDK | API ini tidak berfungsi di Panel beta.2 |
| `COMPONENT_NAMES`, `ReplacementProps`, `ComponentPartProps` | ❌ tidak ditemukan dalam sumber SDK yang diambil | tipe dan konstanta tidak tersedia |
| `createComponentTestHost` (`@pterodactyl/sdk/testing`) | ❌ tidak ditemukan | test penggantian komponen tidak bisa dijalankan |
| Model tema folder: `themes/<id>/theme.json` + `tokens.css` | ❌ | tidak berlaku. Di beta.2, tema adalah extension (lihat di bawah) |
| `p:theme:apply` | ❌ | perintah ini tidak ada. Yang ada: `p:theme:list`, `p:theme:activate {id}`, `p:theme:reset` |

Fitur lain yang saya periksa di dokumen (command `p:extension:*`, `ApplicationApi`, `Fields`, progres pekerjaan, event operasi server, rute akar, `forms.extend`, `useCurrentResource`, `PanelLink`) **ada** di beta.2. Pemeriksaan ini tidak menyeluruh: lihat bagian "Yang belum diverifikasi".

## Fitur yang ada di beta.2 tetapi belum didokumentasikan

Ini hasil pembacaan kode. Jika Anda mengandalkan dokumen saja, fitur ini terlewat.

| Fitur (kode) | Di mana | Catatan |
|---|---|---|
| ID `classic` dicadangkan | `ExtensionManifest::RESERVED_IDS` | dokumen hanya menyebut `pterodactyl`, `panel`, `core` |
| Tipe setting `color`, `textarea`, `multiselect`, `list`, `file` | `ExtensionSettingDefinition::FIELDS` | dokumen hanya mendaftar `text`, `password`, `number`, `toggle`, `select` (lima tipe). Kode mengenal **sepuluh** |
| `p:extension:make --theme`, `--css-only`, `--extends` | `MakeCommand.php` | pembuatan tema dan tema anak |
| `p:extension:install --replace` | `InstallCommand.php` | menimpa extension dengan ID sama |
| Pemasangan dari URL bertanda tangan | `InstallCommand.php`, `config/extensions.php` (`signed_urls`), `ExtensionUrlDownloader` | aktif secara bawaan. Lihat [uji dan paket](uji-dan-paket.md#jalur-pemasangan-dari-url-kode-tidak-ada-di-dokumen) |
| `p:extension:pack --sourcemaps` | `PackCommand.php` | `*.map` dikecualikan kecuali opsi ini |
| `p:extension:types` default untuk tema: `src/theme-types.ts` | `TypesCommand.php` | dokumen hanya menyebut default extension |
| Aturan nama migrasi unik | `ExtensionCompatibility::assertMigrationsAreUnique` | nama yang bentrok membuat migrasi tidak pernah jalan |
| Aturan tabrakan autoloader Composer (`config.autoloader-suffix`) | `ExtensionCompatibility::assertDistinctAutoloader` | tabrakan membuat seluruh request gagal |
| Aturan tema: `theme.extends`, `schemes`, tipe setting tema | `ThemeRepository`, `ThemeSetting`, `ThemeDefinition`, validator | lihat [data dan gaya](data-dan-gaya.md#tema) |

## Selisih yang saling bertentangan di dokumen

Dokumen upstream sendiri tidak konsisten. Ini bukan kesalahan kode:

| Topik | Nilai yang berbeda | Lokasi |
|---|---|---|
| `requires.sdk` untuk penggantian komponen | `>=2.0.0-beta.3 <3.0` | `frontend.mdx` |
| `requires.sdk` pada contoh manifest | `^2.0.0-beta.4` | `building.mdx` |
| `requires.sdk` pada `hello-world` | `>=2.0.0-beta.5 <3.0` | `packages/hello-world/extension.json` di tag |
| `requires.sdk` pada paket `unix` kita | `>=2.0.0-beta.6 <3.0` | `extensions/unix/extension.json` |
| Kunci view di manifest | `ui.components` (dokumen) vs `ui.views` (`hello-world` tag dan validator) | `frontend.mdx` vs tag beta.2 |
| Pemeriksaan wajib `requires.sdk` | "dengan penggantian komponen" (dokumen) vs `required_with:ui.views` (kode) | `reference.mdx` vs `ExtensionManifestValidator.php` |

**Kesimpulan:** nilai `requires.sdk` yang benar untuk Panel beta.2 adalah apa pun yang memuat `2.0.0-beta.6`. `>=2.0.0-beta.6 <3.0` dan `^2.0.0-beta.4` keduanya memenuhi itu. `>=2.0.0-beta.3`, `beta.4`, dan `beta.5` juga memenuhinya, sehingga nilai-nilai itu tidak salah secara teknis. Yang bermasalah adalah **kunci `ui.components`**, karena beta.2 tidak mengenalnya.

## Tema

Ini selisih terbesar, karena menyangkut cara tema dipasang.

| Aspek | Dokumen (Themes, branch `v2`) | Beta.2 (kode) |
|---|---|---|
| Lokasi tema | direktori `themes/<id>/` dengan `theme.json` dan `tokens.css` | extension dengan `"type": "theme"` di `extensions/` |
| Mengaktifkan | `php artisan p:theme:apply <id>` | `p:extension:install --enable`, lalu `p:theme:activate <id>` |
| Mengembalikan | `p:theme:reset` | `p:theme:reset` (sama) |
| Daftar | `p:theme:list` | `p:theme:list` (sama) |
| Pengaturan | tidak dibahas (hanya token CSS) | `theme.settings` dengan tipe `color`, `select`, `toggle`, `number`, `text`, `image` |
| Gaya | `tokens.css` dengan token CSS | `dist/theme.css` (stylesheet wajib) dengan skema `dark` dan `light` |
| Pewarisan | tidak dibahas | `theme.extends` (bawaan `classic`) |

Repositori ini memakai model beta.2 lewat paket `unix` (`type: theme`, `theme.stylesheet: dist/theme.css`). **Itu sudah benar** untuk Panel yang dikunci. Panduan Themes upstream akan menyesatkan jika diikuti untuk Panel ini.

## Bentuk paket yang dipakai repositori ini

Saya memeriksa paket resmi di lock dengan membaca isi zip, tanpa mengekstrak atau menjalankan apa pun:

| Paket | Versi | sha256 cocok lock | Manifest | Catatan |
|---|---|---|---|---|
| `announcements` | 1.0.0 | ✅ | `requires`: `panel ^2.0.0-dev`, `sdk ^2.0.0-beta.4`, `php ^8.3`; `ui.prefix` `ann`; layar `area: admin` | diunduh dari `pterodactyl/extensions` v1.0.1 |
| `custom-buttons` | 1.0.0 | ✅ | sama seperti di atas; `ui.prefix` `cb`; layar `area: admin` | |
| `unix` (lokal) | 1.0.0 | ✅ | `type: theme`; `requires`: `panel ^2.0.0-dev`, `sdk >=2.0.0-beta.6 <3.0`; `theme.stylesheet: dist/theme.css` | dibangun dan disimpan di `extensions/unix/unix.pteroext` |
| `redirect`, `dark-theme` | belum diunduh | belum dicek | belum dicek | di lock sebagai komentar; **belum dipasang dan belum ditinjau** |

Tidak ada manifest yang dipakai memakai `ui.components`. Saya membaca manifest-nya, tetapi belum menjalankan validator beta.2 terhadapnya: itu pekerjaan yang masih terbuka.

## Dampak untuk repositori ini

| Area | Status | Tindakan |
|---|---|---|
| Hash paket di lock | ✅ cocok untuk ketiga paket | tidak ada |
| Tema `unix` | ✅ sesuai model beta.2 | jangan mengikuti panduan Themes folder |
| Volume Docker | ✅ `panel_extensions` → `/app/extensions` dan `panel_extension_assets` → `/app/public/assets/extensions` sesuai dokumen Docker | tidak ada |
| `PTERODACTYL_EXTENSIONS_ENABLED` | ✅ diteruskan dari `PANEL_EXTENSIONS_ENABLED` | tidak ada |
| Pemasangan dari URL bertanda tangan | ⚠ aktif secara bawaan di Panel; repositori tidak memakainya | **keputusan terbuka**: set `PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED=false` di Panel untuk menutup jalur ini. Belum saya terapkan dan belum diuji |
| Penggantian komponen | ❌ tidak tersedia di beta.2 | jangan merancang extension yang bergantung padanya sampai Panel yang dikunci mendukungnya |
| Versi Panel di masa depan | ⚠ dokumen sudah membahas fitur yang lebih baru | saat naik versi, jalankan ulang pemeriksaan di [sumber](sumber.md#cara-memverifikasi-ulang) dan perbarui halaman ini |
| `ID` yang dicadangkan | ✅ paket kita tidak memakai `classic` | jika membuat extension baru, hindari `classic` |

## Yang belum diverifikasi

| Hal | Mengapa | Catatan |
|---|---|---|
| Batas ikon 512 KB dan 2048 px | tertulis di `manifest.schema.json` (SDK) dan dokumen, tetapi penegakannya belum saya temukan di kode yang dibaca | anggap sebagai aturan dokumen |
| Polling 1,5 detik di `useExtensionJobProgress` | runtime SDK tidak ada di sumber yang diambil. Hanya tipe (`progress.d.ts`) | dari dokumen |
| Isi lengkap daftar slot | disalin dari dokumen, belum dicocokkan satu per satu dengan kode | lihat [referensi](referensi.md#slot) |
| Perilaku `ui.components` saat diabaikan | inferensi dari validator, belum dijalankan | perlu uji di Panel beta.2 nyata |
| Dampak `PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED=false` | belum diuji | |
| Panel stabil `v1.15.1` | di luar lingkup; repositori mengunci 2.0 | |
| `redirect` dan `dark-theme` | belum ditinjau | lihat lock |

## Lihat juga

- [Sumber dan metode](sumber.md): URL, commit, dan cara verifikasi ulang.
- [Frontend](frontend.md#penggantian-komponen): perilaku penggantian komponen menurut dokumen.
- [Data dan gaya](data-dan-gaya.md#tema): model tema beta.2.

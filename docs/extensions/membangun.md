# Membangun extension: scaffold, ID, manifest, ikon, kompatibilitas

> **Jenis:** Panduan · **Per:** 2026-10-20 · **Sumber utama:** [Building Extensions](https://docs.pterodactyl.io/v2/extensions/building) (`content/docs/v2/extensions/building.mdx`) · **Diperiksa di kode:** `MakeCommand.php`, `ExtensionManifestValidator.php`, `ExtensionManifest.php` pada tag `v2.0.0-beta.2` · **Kembali ke:** [indeks extension](README.md)

Extension punya backend PHP yang berjalan di dalam Panel seperti paket Laravel, frontend React yang dimuat browser, atau keduanya. Halaman ini memandu pembuatan kerangka paket dan penulisan `extension.json`. Contoh yang dipakai dokumen upstream adalah **Server Notes**: halaman "Notes" di setiap server, catatan yang tampil di atas konsol, tabel sendiri, dan pengaturan panjang maksimum catatan.

Urutan kerja upstream terdiri dari lima bagian: halaman ini, [backend](backend.md), [frontend](frontend.md), [data dan gaya](data-dan-gaya.md), dan [uji serta paket](uji-dan-paket.md).

## Prasyarat

| Kebutuhan | Versi |
|---|---|
| Checkout Panel 2.0 dalam mode pengembangan | sesuai versi yang Anda kembangkan |
| PHP | 8.3 atau lebih baru |
| Composer | terbaru |
| Node.js | 22.12 atau lebih baru |

Extension yang dibuat dari checkout Panel memakai paket `@pterodactyl/sdk` lokal. Setelah dependensi frontend Panel terpasang, bangun runtime test SDK dari root Panel:

```bash
npm run sdk:testing
```

Ulangi perintah itu setiap kali sumber SDK berubah.

## Membuat kerangka

Dari checkout Panel:

```bash
php artisan p:extension:make server-notes --name="Server Notes" --description="Keep shared notes on each server."
```

Opsi yang diterima `p:extension:make` menurut kode (tag `v2.0.0-beta.2`):

| Opsi | Arti | Di dokumen upstream? |
|---|---|---|
| `--name` | nama tampilan; bawaannya ID dalam huruf judul | ya |
| `--description` | deskripsi singkat | ya |
| `--author` | nama penulis | ya |
| `--prefix` | awalan Tailwind untuk kelas extension, 2 sampai 12 huruf kecil; bawaannya diturunkan dari ID | ya |
| `--no-ui` | hanya backend, tanpa frontend | ya |
| `--out` | direktori induk; paket dibuat di `<out>/<id>` | ya |
| `--force` | timpa direktori yang sudah ada | ya |
| `--theme` | buat **tema**: stylesheet, override tata letak, skin, pengaturan, dan test | **tidak** |
| `--css-only` | dengan `--theme`: tema berupa CSS saja, tanpa entri JavaScript | **tidak** |
| `--extends` | dengan `--theme`: tema induk yang diwarisi; kerangka menjadi tema anak | **tidak** |

Tema dibahas di [data dan gaya](data-dan-gaya.md#tema) dan di [referensi](referensi.md). Paket `unix` yang dipakai repositori ini adalah tema.

Lalu pasang dependensi, periksa tipe, uji, bangun, dan pasang di Panel pengembangan:

```bash
cd extensions/server-notes
npm install
npm run typecheck
npm test
npm run build
cd ../..
php artisan p:extension:install extensions/server-notes --enable
```

## ID extension

ID menamai extension di mana saja: direktori, URL, dan pengaturan.

| Aturan | Sumber |
|---|---|
| Diawali huruf kecil; hanya huruf kecil, angka, dan tanda hubung; panjang maksimum 48 | kode: `ID_REGEX = '/^[a-z][a-z0-9-]{0,47}$/D'` |
| Direktori harus bernama sama dengan ID | dokumen upstream |
| ID yang dicadangkan: `pterodactyl`, `panel`, `core`, dan **`classic`** | dokumen upstream menyebut tiga yang pertama; kode juga memuat `classic` (`ExtensionManifest::RESERVED_IDS`), karena `classic` adalah nama tema bawaan |

## Struktur direktori

Dengan berkas dari panduan ini, Server Notes berbentuk:

```text
server-notes/
├── .github/workflows/ci.yml
├── .gitignore
├── extension.json
├── README.md
├── database/
│   └── migrations/
│       └── 2026_09_29_000000_create_ext_server_notes_notes_table.php
├── routes/
│   └── server.php
├── scripts/
│   └── externalize-api.mjs
├── src/
│   ├── ServerNotesProvider.php
│   ├── Http/Controllers/NoteController.php
│   ├── Models/Note.php
│   └── client/
│       ├── index.tsx
│       ├── styles.css
│       ├── api.ts
│       ├── config.ts
│       ├── NotePreview.tsx
│       └── screens/
│           ├── NotesScreen.tsx
│           └── NotesScreen.spec.tsx
├── openapi-ts.config.ts
├── package.json
├── postcss.config.mjs
├── tsconfig.json
├── vite.config.mjs
└── vitest.config.mjs
```

Perintah `make` juga membuat contoh rute di `routes/client.php`, `StatusController`, dan `ServerScreen` beserta testnya. Panduan menggantinya dengan berkas di atas. Dengan `--no-ui`, hanya manifest, provider, contoh controller dan rute, direktori migrasi, `.gitignore`, dan `README.md` yang dibuat.

## Manifest: `extension.json`

Berkas ini di akar extension menjelaskan apa extension itu dan cara memuatnya. Contoh dari panduan upstream:

```json
{
    "$schema": "./node_modules/@pterodactyl/sdk/manifest.schema.json",
    "id": "server-notes",
    "name": "Server Notes",
    "version": "1.0.0",
    "requires": {
        "panel": "^2.0.0-dev",
        "sdk": "^2.0.0-beta.4",
        "php": "^8.3"
    },
    "description": "Keep shared notes on each server.",
    "provider": "ServerNotes\\ServerNotesProvider",
    "autoload": {
        "ServerNotes\\": "src"
    },
    "ui": {
        "entry": "dist/client.js",
        "mode": "native",
        "prefix": "sn",
        "screens": [
            {
                "id": "notes",
                "area": "server",
                "path": "notes",
                "nav": { "label": "Notes" }
            }
        ]
    }
}
```

- `provider` dan `autoload` memuat kode PHP.
- `ui` memuat bundel frontend dan mendeklarasikan halaman-halamannya.
- `ui.prefix` adalah awalan Tailwind untuk kelas extension. Panel menolak build yang kelas atau variabel tema-nya tidak memakai awalan itu.
- Hapus kunci yang tidak dipakai. Daftar lengkap setiap kunci dan aturannya ada di [referensi manifest](referensi.md#manifest).

Validasi manifest dilakukan saat paket dipasang dan diaktifkan. Kode validator (tag `v2.0.0-beta.2`) memeriksa, antara lain:

| Aturan | Nilai di kode |
|---|---|
| `ui.entry` | harus tepat `dist/client.js` |
| `ui.mode` | hanya `native` |
| `ui.prefix` | `^[a-z]{2,12}$`, tidak boleh memakai nama varian Tailwind atau nama yang dicadangkan |
| `type` | `extension` atau `theme` |
| `routes.root` | maksimum 8 prefiks, masing-masing `^[a-z][a-z0-9-]{0,47}$` |
| `ui.screens` | maksimum 64 entri; `area` hanya `account`, `server`, atau `admin` |
| Parameter path layar | `$id` dicadangkan; parameter harus unik |

## Ikon

Admin melihat setiap extension sebagai kartu di halaman **Extensions**. Tanpa `icon`, kartu menampilkan inisial. Ada dua bentuk.

**Nama ikon Lucide** (kebab-case, mis. `notebook-pen`):

```json
"icon": "notebook-pen"
```

**Gambar di dalam paket**, dengan jalur relatif (mis. `icon.png`):

```json
"icon": "icon.png"
```

Aturan gambar menurut dokumen upstream dan skema manifest di SDK (`manifest.schema.json`):

- PNG, JPEG, atau WebP. SVG tidak didukung. Jenis dinilai dari isi berkas, bukan namanya.
- Maksimum **512 KB** dan **2048 piksel** per sisi.
- Disarankan persegi, minimal 128 piksel. Ditampilkan 40 piksel.
- Jalur tidak boleh memakai nama yang diawali titik, dan tidak boleh keluar dari extension. Symlink yang menunjuk ke luar ditolak.

Angka 512 KB dan 2048 piksel tertulis di dokumen dan skema, tetapi penegakannya belum saya temukan di kode yang dibaca. Anggap sebagai aturan dokumen sampai diverifikasi. `p:extension:doctor` memperingatkan ikon yang tidak bisa tampil.

## Kompatibilitas

Nyatakan versi yang didukung extension dengan `requires.panel`, `requires.sdk`, dan `requires.php`. Syntax-nya Composer, mis. `^2.0.0-beta.4`, `>=8.3 <9.0`.

```json
"requires": {
    "extensions": {
        "shared-notes": "^1.0"
    }
}
```

- Extension yang disyaratkan harus aktif sebelum extension Anda bisa aktif.
- Panel memuat dependensi lebih dulu, menolak siklus dependensi, dan melewati extension yang syaratnya tidak terpenuhi. Bila dependensi gagal, dependennya ikut tidak dimuat.
- Kode (`ExtensionCompatibility::runtimeFailureReason`) membandingkan `requires.panel` dengan `app.version` (nilai `canary` diperlakukan sebagai `2.0.0-dev`), `requires.sdk` dengan `sdk_version` di `config/extensions.php` (`2.0.0-beta.6` di tag beta.2), dan `requires.php` dengan versi PHP yang berjalan.
- `$schema` mengaktifkan pelengkapan manifest di editor yang mendukung JSON Schema.

**Catatan `requires.sdk`:** nilainya berbeda di tiga tempat dokumen dan contoh. Contoh manifest memakai `^2.0.0-beta.4`, bagian komponen memakai `>=2.0.0-beta.3 <3.0`, dan contoh `hello-world` memakai `>=2.0.0-beta.5 <3.0`. SDK yang dikirim bersama tag beta.2 adalah `2.0.0-beta.6`. Selisihnya dicatat di [kompatibilitas](kompatibilitas.md#selisih-yang-saling-bertentangan-di-dokumen).

Pada validator tag beta.2, `requires.sdk` **wajib** hanya bila `ui.views` dipakai (`required_with:ui.views`). Dokumen upstream menyebutnya wajib untuk penggantian komponen, yang memakai nama `ui.components`. Lihat [kompatibilitas](kompatibilitas.md#fitur-yang-didokumentasikan-tetapi-belum-ada-di-beta2).

Contoh `extension.json` di paket resmi `hello-world` (tag beta.2) memakai `ui.views`, bukan `ui.components`:

```json
"views": ["dashboard.serverCard", "server.files.details", "server.files.editor"]
```

## Lihat juga

- [Backend](backend.md): provider, rute, migrasi, pengaturan.
- [Frontend](frontend.md): slot, layar, tab, kolom tabel, penggantian komponen.
- [Mengelola](mengelola.md): pasang, aktifkan, perbarui, hapus.
- [Kompatibilitas](kompatibilitas.md): apa yang sudah ada di Panel beta.2 dan apa yang baru di dokumen.

# Uji, build, dan paket extension

> **Jenis:** Panduan · **Per:** 2026-10-20 · **Sumber utama:** [Testing and Packaging](https://docs.pterodactyl.io/v2/extensions/testing-and-packaging) (`testing-and-packaging.mdx`) · **Diperiksa di kode:** `PackCommand.php`, `DevCommand.php`, `DoctorCommand.php`, `InstallCommand.php`, `config/extensions.php` pada tag `v2.0.0-beta.2` · **Kembali ke:** [indeks extension](README.md)

Uji extension sebelum dibagikan, lalu bangun dan kemas. Halaman ini juga menjelaskan model keamanan extension dan satu jalur pemasangan yang tidak dibahas dokumen upstream.

## Uji

Scaffold frontend menyertakan Vitest, jsdom, Testing Library, dan satu test yang berjalan terhadap runtime SDK asli. Jalankan dari dalam direktori extension:

```bash
npm run typecheck
npm test
```

Untuk komponen yang butuh router, pengguna saat ini, izin, server, atau cache query Panel, pakai `createExtensionTestHost` dan `createTestServer` dari `@pterodactyl/sdk/testing`. Contoh untuk layar Notes: mock respons API extension, lalu sediakan konteks server:

```tsx title="src/client/screens/NotesScreen.spec.tsx"
import { afterEach, expect, test, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { createExtensionTestHost, createTestServer } from '@pterodactyl/sdk/testing';
import NotesScreen from './NotesScreen';

vi.mock('../api', async (importOriginal) => ({
    ...(await importOriginal<typeof import('../api')>()),
    getNote: vi.fn().mockResolvedValue({ body: 'Remember to make a backup.', updated_at: null }),
}));

let host: ReturnType<typeof createExtensionTestHost> | undefined;
afterEach(() => {
    cleanup();
    host?.dispose();
    host = undefined;
});

test('loads notes inside the Panel', async () => {
    host = createExtensionTestHost({
        extensionId: 'server-notes',
        server: createTestServer({ owner: false, permissions: ['file.update'] }),
    });
    render(<NotesScreen />, { wrapper: host.Wrapper });
    expect(await screen.findByDisplayValue('Remember to make a backup.')).toBeTruthy();
});
```

- Buat satu host per test. Setelah selesai, lepas wrapper dari DOM, lalu panggil `dispose()`.
- Host juga mendukung resource admin bertipe, navigasi, event websocket, dan perubahan koneksi.
- `vitest.config.mjs` dari scaffold memasok alias SDK dan setup lewat `@pterodactyl/sdk/vitest`. Pertahankan saat konfigurasi diubah.
- Rute dan job backend butuh test sendiri untuk validasi dan otorisasi. Scaffold menyertakan workflow GitHub Actions yang menjalankan pemeriksaan tipe, test, dan build frontend.

Dokumen upstream menyebut `createComponentTestHost` untuk menguji penggantian komponen. Fungsi itu **tidak ada** di SDK beta.2 (lihat [kompatibilitas](kompatibilitas.md#fitur-yang-didokumentasikan-tetapi-belum-ada-di-beta2)).

## Build

```bash
npm run build
```

Perintah ini menulis `dist/client.js` dan satu berkas per layar.

Sebelum memasang, periksa paket dari root Panel:

```bash
php artisan p:extension:doctor extensions/server-notes
```

`p:extension:doctor` memeriksa, berdasarkan kode beta.2 dan dokumen:

- manifest, lewat validator yang sama dengan saat pemasangan;
- kompatibilitas runtime dan dependensi extension;
- direktori autoload;
- berkas frontend hasil build;
- ikon: nama Lucide yang tidak dikirim Panel ini (peringatan), atau gambar yang hilang, terlalu besar, atau bukan PNG, JPEG, WebP.

Perintah ini melaporkan error tanpa memasang paket.

### Mode pengembangan

```bash
php artisan p:extension:dev extensions/server-notes --watch --enable
```

Opsi yang diterima (kode `DevCommand.php`): `--watch` (pantau sumber frontend) dan `--enable` (aktifkan setelah build awal). Perilakunya:

- Menjalankan build awal, lalu `npm run dev` di paket, dan mempublikasikan ulang setiap build yang berhasil.
- Build yang gagal mempertahankan versi terakhir yang berhasil dipublikasikan.
- Dengan `APP_DEBUG=true`, browser dimuat ulang setelah setiap publikasi yang berhasil. Buka Panel setelah watcher dimulai.
- Hentikan dengan Ctrl+C.
- Tanpa `--watch`, perintah membangun dan mempublikasikan sekali.

## Kemas

```bash
php artisan p:extension:pack extensions/server-notes --output=server-notes.pteroext
```

Opsi (kode `PackCommand.php`):

| Opsi | Arti |
|---|---|
| `path` (argumen) | direktori extension yang sudah dibangun |
| `--output` | nama berkas arsip. Bawaannya `{id}-{version}.pteroext` di direktori kerja |
| `--force` | timpa arsip yang sudah ada. Tanpa opsi ini, arsip yang ada dibiarkan dan perintah gagal |
| `--sourcemaps` | sertakan berkas `*.map`. **Bisa menyematkan seluruh sumber** |

Isi arsip (dokumen upstream):

- manifest;
- gambar yang dinamai di `icon`;
- direktori runtime: `routes`, `database/migrations`, `resources`, aset hasil build, dependensi vendor, dan direktori autoload PHP yang dideklarasikan.

Yang dikecualikan: berkas dengan nama diawali titik, symlink, `node_modules`, serta direktori test dan coverage. Berkas `*.map` juga dikecualikan kecuali `--sourcemaps` diberikan (kode `PackCommand`).

Sebelum membagikan arsip, periksa isinya. Taruh berkas runtime kustom di direktori yang dikemas packager. Berkas di bawah direktori autoload PHP, termasuk `src/client`, ikut dikemas kecuali dikecualikan aturan di atas.

Administrator memasang berkas ini sesuai [mengelola extension](mengelola.md#pasang).

## Keamanan

Extension berjalan dengan hak akses yang sama dengan Panel. Perlakukan seperti kode Panel. Dokumen upstream mencatat empat aturan:

1. Validasi setiap request dan periksa izin sebelum mengubah data.
2. Jangan pernah mengekspos rahasia sebagai pengaturan frontend. Setiap pengguna yang sudah masuk bisa membaca konfigurasi publik.
3. Tandai pengaturan rahasia dengan `secret()`, atau gunakan `setSecret` untuk nilai yang dikelola.
4. Beri awalan pada tabel basis data agar tidak bertabrakan dengan tabel Panel.

Dokumen juga meminta Anda mendeklarasikan dan menguji versi Panel, SDK, PHP, dan extension yang didukung. Batasan versi memeriksa kompatibilitas, tetapi tidak menggantikan test perilaku extension.

### Jalur pemasangan dari URL (kode, tidak ada di dokumen)

`p:extension:install` menerima argumen `path` berupa **URL install bertanda tangan** (*signed install URL*), selain berkas lokal dan direktori. Dari `config/extensions.php` (tag beta.2):

| Setting | Nilai bawaan | Arti |
|---|---|---|
| `PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED` | `true` | pemasangan dari URL **aktif secara bawaan** |
| `signed_urls.public_key` | kunci publik tertanam | URL harus ditandatangani dengan kunci privat yang sesuai |
| `signed_urls.issuer` | `Infraly, LLC` | penerbit yang diharapkan |
| `signed_urls.audience` | `pterodactyl-panel` | audiens yang diharapkan |

Repositori ini **tidak** memakai jalur itu: `./ptero ext` hanya memasang paket dari `extensions.lock` yang dicocokkan sha256-nya. Untuk Panel yang tidak memerlukan pemasangan dari URL, pertimbangkan mematikannya dengan `PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED=false` di lingkungan Panel. Saya belum menguji dampak nilai itu.

### Yang dicek repositori ini

- Hanya id di `extensions/extensions.lock` yang bisa dipasang, dengan sha256 yang cocok. Lihat [mengelola](mengelola.md#di-repositori-ini).
- `./ptero ext vet` memeriksa paket sebelum dipasang, tetapi itu penyaring awal. Pemeriksaannya mencari panggilan `exec`, `shell_exec`, `system`, `passthru`, `proc_open`, `eval`, HTTP keluar dari PHP, `unserialize`, dan `base64_decode`.
- Paket yang sudah ada di lock ditinjau manual sebelum dimasukkan, lalu hash-nya dikunci.

## Lihat juga

- [Mengelola](mengelola.md): pasang, aktifkan, perbarui, hapus.
- [Backend](backend.md#kode-autoload-dan-rute-akar-kode): aturan autoload dan namespace yang diperiksa kode.
- [Kompatibilitas](kompatibilitas.md): versi SDK dan Panel yang dikirim.

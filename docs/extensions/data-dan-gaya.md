# Data, API, komponen, gaya, dan tema

> **Jenis:** Panduan + referensi · **Per:** 2026-10-20 · **Sumber utama:** [Data and Styling](https://docs.pterodactyl.io/v2/extensions/data-and-styling) (`data-and-styling.mdx`) dan [Themes](https://docs.pterodactyl.io/v2/guides/customization/themes) (`guides/customization/themes.mdx`) · **Diperiksa di kode:** `ThemeRepository.php`, `ThemeSetting.php`, `ThemeDefinition.php` pada tag `v2.0.0-beta.2` · **Kembali ke:** [indeks extension](README.md)

Halaman ini membahas cara frontend extension membaca data Panel, memanggil API-nya sendiri, memakai komponen dan gaya Panel, menerjemahkan teks, dan mendeklarasikan tema. Semua contoh berada di konteks komponen frontend, yaitu slot, layar, kolom, atau penggantian.

> [!WARNING]
> **Tema.** Panduan Themes upstream menjelaskan model lain: folder `themes/` dengan `theme.json` dan `tokens.css`, diterapkan dengan `p:theme:apply`. Model itu **tidak ada** di tag `v2.0.0-beta.2`. Di beta.2, tema adalah **extension** dengan `type: theme`, diaktifkan dengan `p:theme:activate`. Bagian [tema](#tema) mengikuti kode beta.2, dan perbedaannya dicatat di [kompatibilitas](kompatibilitas.md#tema).

## Membaca data Panel

SDK menyediakan hook untuk data yang biasa dibutuhkan halaman. Server Notes memakai dua:

```tsx
import { useCurrentServerRequired, useServerPermission } from '@pterodactyl/sdk';

const server = useCurrentServerRequired();
const canEdit = useServerPermission('file.update');
```

- `useCurrentServerRequired` mengembalikan server saat ini di halaman server.
- `useServerPermission` mengembalikan apakah pengguna saat ini punya izin itu di server tersebut.
- Hook lain mengembalikan pengguna saat ini, pengaturan situs, dan event server langsung. Daftar lengkapnya di [referensi hook](referensi.md#hook).

SDK juga membuka query dan mutasi Panel untuk file, konfigurasi startup, dan backup:

```tsx
import { useCurrentServerRequired, useServerFiles } from '@pterodactyl/sdk';

const server = useCurrentServerRequired();
const files = useServerFiles(server.attributes.uuid, '/', (response) => response.data);
```

- Berikan UUID server ke hook ini agar memakai entri cache yang sama dengan halaman asli.
- Factory opsi query tersedia untuk `useQuery`, prefetch, atau akses cache langsung.
- Hook mutasi untuk tulis file, perubahan startup, dan pembuatan backup ikut memperbarui atau membatalkan cache yang sama. Tulis startup dijalankan satu per satu per server.
- Bila endpoint Anda sendiri mengubah data asli, panggil `await invalidateServerData(uuid, domains)` setelah berhasil. Domain yang didukung: `server`, `files`, `fileContent`, `startup`, dan `backups`.

## Panggilan ke API Anda

Panggil backend lewat klien `http` dari SDK. Itu klien yang dipakai Panel, jadi permintaannya sudah terautentikasi. Server Notes menyimpan pemanggilannya di `src/client/api.ts`:

```ts
import { http } from '@pterodactyl/sdk';

export interface Note {
    body: string;
    updated_at: string | null;
}

const noteUrl = (server: string) => `/api/client/servers/${server}/extensions/server-notes/note`;

export const noteQueryKey = (server: string) => ['server-notes', server] as const;

export async function getNote(server: string): Promise<Note> {
    const { data } = await http.get<Note>(noteUrl(server));

    return data;
}

export async function saveNote(server: string, body: string): Promise<Note> {
    const { data } = await http.put<Note>(noteUrl(server), { body });

    return data;
}
```

Panel berbagi salinan TanStack Query dengan extension, jadi `useQuery` dan `useMutation` bisa langsung dipakai. Layar Notes memuat dan menyimpan catatan seperti ini:

```tsx
import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
    Button,
    ServerContentBlock,
    Spinner,
    TextArea,
    TitledGreyBox,
    httpErrorToHuman,
    toast,
    useCurrentServerRequired,
    useServerPermission,
} from '@pterodactyl/sdk';
import { getNote, noteQueryKey, saveNote } from '../api';
import { maxLength } from '../config';

export default function NotesScreen() {
    const server = useCurrentServerRequired();
    const identifier = server.attributes.identifier;
    const canEdit = useServerPermission('file.update');
    const queryClient = useQueryClient();
    const [body, setBody] = useState('');

    const note = useQuery({ queryKey: noteQueryKey(identifier), queryFn: () => getNote(identifier) });

    useEffect(() => {
        if (note.data) {
            setBody(note.data.body);
        }
    }, [note.data]);

    const save = useMutation({
        mutationFn: () => saveNote(identifier, body),
        onSuccess: (saved) => {
            queryClient.setQueryData(noteQueryKey(identifier), saved);
            toast.success('Notes saved.');
        },
        onError: (error) => toast.error(httpErrorToHuman(error)),
    });

    return (
        <ServerContentBlock title={'Notes'}>
            <TitledGreyBox title={'Notes'}>
                {note.isLoading ? (
                    <Spinner centered />
                ) : (
                    <div style={{ display: 'grid', gap: '1rem' }}>
                        <TextArea
                            rows={12}
                            value={body}
                            maxLength={maxLength()}
                            readOnly={!canEdit}
                            onChange={(event) => setBody(event.target.value)}
                        />
                        {canEdit && (
                            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                                <Button isLoading={save.isPending} onClick={() => save.mutate()}>
                                    Save notes
                                </Button>
                            </div>
                        )}
                    </div>
                )}
            </TitledGreyBox>
        </ServerContentBlock>
    );
}
```

`httpErrorToHuman` mengubah error API menjadi pesan yang bisa ditampilkan kepada pengguna.

### Klien API yang dihasilkan

Scaffold menyertakan generator OpenAPI dan skrip yang menghubungkan klien hasilnya ke transport Panel. Aktifkan extension agar rutenya dimuat, dokumentasikan parameter dan respons controller untuk Scribe, lalu dari root Panel:

```bash
composer docs:openapi
npm run extension:api:generate -- server-notes
```

Perintah itu mengambil rute dari area API client, server, admin, dan application, menulis `extensions/server-notes/openapi.yaml`, dan menghasilkan kode di `src/client/generated`. Fungsi hasil generate mengimpor dari `@pterodactyl/sdk/api`, sehingga autentikasi dan query client Panel tetap dipakai. Jika sudah punya `openapi.yaml`, jalankan `npm run api:generate` di dalam paket extension.

Dokumen upstream tidak menjelaskan lebih jauh perintah-perintah ini, dan belum saya uji.

## Komponen dan gaya

SDK menyertakan komponen Panel, seperti `Button`, `Input`, `TextArea`, `Select`, `Switch`, `Dialog`, `Alert`, `TitledGreyBox`, dan `ServerContentBlock`, agar halaman extension sama dengan Panel. `toast` menampilkan notifikasi. Daftar lengkapnya ada di [referensi komponen](referensi.md#komponen).

Entri stylesheet scaffold, `src/client/styles.css`, memuat tema dan utilitas Tailwind serta pemetaan SDK ke token desain Panel:

```css title="src/client/styles.css"
@import 'tailwindcss/theme.css' layer(theme);
@import 'tailwindcss/utilities.css' layer(utilities);
@import '@pterodactyl/sdk/theme.css';
@source './**/*.{ts,tsx}';
```

- Pakai kelas seperti `bg-card`, `text-foreground`, dan `border-border` agar mengikuti tema aktif.
- **Jangan** masukkan preflight Tailwind ke gaya extension. Itu akan mengatur ulang elemen Panel. Dokumen upstream memberi peringatan yang sama.
- Selector CSS kustom harus memakai awalan khusus extension.
- Panel memuat stylesheet entri sebelum `setup`, dan memuat gaya chunk layar saat chunk itu diimpor.

## Terjemahan frontend

Panggil `loadExtensionTranslations()` di provider dan tambahkan grup terjemahan, mis. `resources/lang/en/messages.php`. Baca di layar dan slot dengan `useExtensionTranslation('messages')`:

```tsx
import { useExtensionTranslation } from '@pterodactyl/sdk';

const { t, ready } = useExtensionTranslation('messages');
```

Hook memakai locale Panel saat ini dan namespace `ext-server-notes::messages`. Gunakan `ready` untuk menangani pemuatan, dan `t('title')` untuk membaca kunci `title`.

## Paket bersama

Panel menyediakan React, React DOM, TanStack Query, dan SDK saat runtime. Paket-paket itu tidak ikut di bundel extension Anda, jadi setiap extension memakai salinan milik Panel. Paket lain yang Anda impor ikut dibundel ke dalam extension.

> Impor `toast` dari SDK, **bukan** langsung dari `sonner`. Jika tidak, notifikasi tidak akan muncul. Dokumen upstream memberi peringatan ini.

## Tipe konfigurasi

Tandai pengaturan publik dengan `frontend()` dan tipe nilainya dengan `frontendType(...)`. Aktifkan extension agar definisinya dimuat, lalu dari root Panel hasilkan tipe TypeScript-nya:

```bash
php artisan p:extension:types extensions/server-notes
```

Perintah ini menulis `src/client/extension-types.ts`: ID extension, ID layar sebagai literal, izin yang terdaftar, dan kunci konfigurasi publik. Pengaturan rahasia tidak ikut. Jalur default ini diverifikasi di kode `TypesCommand.php` (tag beta.2). Untuk tema, default-nya `src/theme-types.ts`.

Tipe dipakai bersama `defineConfiguredExtension`. Parser-nya memeriksa nilai saat runtime sebelum fungsi `setup` memakainya:

```tsx
import { defineConfiguredExtension } from '@pterodactyl/sdk';
import type { ExtensionConfig, ExtensionScreenId } from './extension-types';
import { setConfig } from './config';
import NotePreview from './NotePreview';
import './styles.css';

export default defineConfiguredExtension<ExtensionConfig, ExtensionScreenId>(
    (config) => {
        const maxLength = config.max_length ?? 2000;
        if (typeof maxLength !== 'number') throw new Error('Invalid maximum note length.');
        return { ...config, max_length: maxLength };
    },
    {
        setup({ config, slots, screens }) {
            setConfig(config);
            screens.register('notes', () => import('./screens/NotesScreen'));
            slots.register('server.console.before', NotePreview);
        },
    }
);
```

Bila bundel Anda juga dirender sebelum masuk, parser harus menangani konfigurasi publik yang kosong. Server Notes memakai nilai bawaan di kasus itu.

## Tema

Di Panel beta.2, tema adalah **extension** dengan `"type": "theme"`. Manifestnya mendeklarasikan stylesheet, skema warna, dan pengaturan. Apakah tema juga boleh memuat provider atau rute tidak saya periksa; halaman ini tidak menganjurkannya.

### Manifest tema

Contoh dari paket `unix` yang dipakai repositori ini (`extensions/unix/extension.json`):

```json
{
    "$schema": "./node_modules/@pterodactyl/sdk/manifest.schema.json",
    "id": "unix",
    "type": "theme",
    "name": "Unix",
    "version": "1.0.0",
    "requires": {
        "panel": "^2.0.0-dev",
        "sdk": ">=2.0.0-beta.6 <3.0"
    },
    "description": "Terminal-style day/night theme",
    "author": "surip",
    "icon": "palette",
    "theme": {
        "extends": "classic",
        "stylesheet": "dist/theme.css",
        "schemes": ["dark", "light"],
        "settings": {
            "radius": {
                "type": "number",
                "label": "Corner radius",
                "default": 0.25,
                "min": 0,
                "max": 1.5,
                "step": 0.125,
                "unit": "rem",
                "token": "--radius"
            },
            "compact": {
                "type": "toggle",
                "label": "Compact spacing",
                "default": false,
                "attribute": "data-unix-compact"
            },
            "logo": {
                "type": "image",
                "label": "Logo",
                "help": "Shown in place of the panel name.",
                "token": "--brand-logo"
            }
        }
    }
}
```

Aturan dari kode validator dan kelas tema (tag beta.2):

| Aturan | Nilai |
|---|---|
| `type` | `extension` atau `theme` |
| `theme.stylesheet` | harus tepat `dist/theme.css` (`ThemeDefinition::STYLESHEET`) |
| `theme.schemes` | daftar 1 sampai 2 dari `dark` dan `light` |
| `theme.extends` | bawaannya `classic`. Tema tidak boleh mengextend dirinya sendiri. Induk harus tema aktif (bila bukan `classic`) |
| `ui.prefix` dan `ui.views` | **dilarang** untuk tema (`prohibited_if:type,theme`). Tema membangun stylesheet sendiri |
| `theme` | hanya boleh dipakai bila `type` = `theme` |

### Pengaturan tema

Tipe setting tema (`ThemeSetting::TYPES`): **`color`, `select`, `toggle`, `number`, `text`, `image`**.

| Aturan | Detail |
|---|---|
| Nama setting | `^[a-zA-Z][a-zA-Z0-9_]{0,47}$` |
| `token` | nama custom property CSS, `^--[a-zA-Z][a-zA-Z0-9-]{0,62}$`. Setting mengisi token itu |
| `attribute` | atribut data, `^data-[a-z][a-z0-9-]{0,58}$`. `data-theme` **dilarang**, karena Panel yang mengaturnya |
| `select` | wajib `options` (kunci ber-ID seperti `side`), minimal satu |
| `number` | `min`, `max`, `step` (harus lebih dari 0), dan `unit` (`%` atau 1 sampai 4 huruf kecil) |
| `text` | `maxLength` (bilangan bulat minimal 1) |
| `image` | tidak boleh punya nilai bawaan; diunggah dari halaman Themes |
| Dua setting | tidak boleh menulis `token` atau `attribute` yang sama |
| Nilai bawaan | harus lolos pemeriksaan yang sama dengan nilai tersimpan (mis. di antara `min` dan `max`) |

Kode mendefinisikan prefiks kunci `theme.` untuk pengaturan tema (`ThemeSetting::KEY_PREFIX`). Cara administrator mengisi nilainya di antarmuka belum saya telusuri.

### Mengaktifkan tema

```bash
php artisan p:extension:install /path/ke/unix.pteroext --enable
php artisan p:theme:list
php artisan p:theme:activate unix
php artisan p:theme:reset        # kembali ke classic
```

Tag beta.2 menyediakan `p:theme:list`, `p:theme:activate {id}` (menerima `classic` sebagai id), dan `p:theme:reset`. Tema aktif disimpan di pengaturan Panel (`pterodactyl:theme`). Tema yang gagal dimuat atau tidak aktif tidak bisa diaktifkan.

Repositori ini memakai alur ini lewat `./ptero ext install` dan `PANEL_THEME` (lihat [mengelola](mengelola.md#di-repositori-ini)).

### Membuat tema

Perintah `p:extension:make --theme` membuat kerangka tema (lihat [membangun](membangun.md#membuat-kerangka)). Opsi `--css-only` menghasilkan tema CSS saja tanpa entri JavaScript, dan `--extends <id>` membuat tema anak yang mewarisi tampilan, skin, stylesheet, dan pengaturan induknya. Dokumen upstream belum membahas ketiga opsi itu. Kerangka tema dan pengaturannya belum saya telusuri lebih jauh dari template-nya.

## Lihat juga

- [Frontend](frontend.md): slot, layar, dan penggantian komponen.
- [Membangun](membangun.md): kerangka extension dan `extension.json`.
- [Kompatibilitas](kompatibilitas.md#tema): model tema upstream dan model beta.2.

# Frontend extension: slot, layar, tab, kolom, penggantian komponen

> **Jenis:** Panduan + referensi · **Per:** 2026-10-20 · **Sumber utama:** [Frontend](https://docs.pterodactyl.io/v2/extensions/frontend) (`frontend.mdx`) · **Diperiksa di kode:** `packages/sdk/types/` dan `ExtensionManifestValidator.php` pada tag `v2.0.0-beta.2` · **Kembali ke:** [indeks extension](README.md)

Frontend extension adalah bundel React yang dimuat Panel di browser. Halaman ini memakai contoh Server Notes dari [membangun extension](membangun.md).

> [!WARNING]
> **Penggantian komponen (`ui.components`, `components.replace`) belum ada di Panel beta.2** yang dikunci repositori ini. Dokumen upstream membahasnya, tetapi validator dan SDK di tag `v2.0.0-beta.2` hanya mengenal `ui.views`. Bagian [penggantian komponen](#penggantian-komponen) di bawah menjelaskan perilaku dari dokumen, dengan penanda jelas. Rinciannya dan dampaknya di [kompatibilitas](kompatibilitas.md#fitur-yang-didokumentasikan-tetapi-belum-ada-di-beta2).

## Entry: `src/client/index.tsx`

Frontend dimulai dari `src/client/index.tsx`, yang mengekspor default sebuah definisi extension dengan fungsi `setup`:

```tsx
import { definePterodactylExtension } from '@pterodactyl/sdk';
import './styles.css';
import { setConfig } from './config';
import NotePreview from './NotePreview';

export default definePterodactylExtension({
    setup({ config, slots, screens }) {
        setConfig(config);

        screens.register('notes', () => import('./screens/NotesScreen'));
        slots.register('server.console.before', NotePreview);
    },
});
```

Panel memanggil `setup` sekali saat halaman dimuat. Argumennya:

| Properti | Fungsi |
|---|---|
| `meta` | `id` dan `version` extension |
| `config` | nilai pengaturan frontend ([pengaturan](backend.md#pengaturan)) |
| `components` | mengganti komponen Panel yang didukung (lihat peringatan di atas) |
| `slots` | menaruh komponen di halaman Panel |
| `screens` | menambah halaman sendiri |
| `columns` | menambah kolom ke tabel admin yang didukung |
| `forms` | menggambar field di form admin (lihat [form asli](#form-asli)) |

- `setup` harus mendaftarkan semuanya seketika dan **tidak boleh `async`**. Pendaftaran berlaku bersama setelah `setup` berhasil.
- Layar tidak menerima `config` langsung. Simpan di modul kecil, seperti `src/client/config.ts` pada contoh:

```ts
import type { ExtensionConfig } from '@pterodactyl/sdk';

let config: ExtensionConfig = {};

export function setConfig(value: ExtensionConfig): void {
    config = value;
}

export function maxLength(): number {
    return typeof config.max_length === 'number' ? config.max_length : 2000;
}
```

## Slot

Slot adalah tempat bernama di halaman Panel. Extension menaruh komponen di sana. Untuk memakainya, daftarkan komponen:

```tsx
slots.register('server.console.before', NotePreview);
```

Setiap slot memberi `data` sesuai lokasinya. Slot konsol menerima server saat ini, slot aksi file menerima konteks file dan seleksi, dan sebagian besar slot halaman lain menerima data rute. Contoh Server Notes memakai server dari slot konsol untuk memuat catatan:

```tsx
import { useQuery } from '@tanstack/react-query';
import { TitledGreyBox, type SdkServer } from '@pterodactyl/sdk';
import { getNote, noteQueryKey } from './api';

export default function NotePreview({ data: server }: { data: SdkServer }) {
    const identifier = server.attributes.identifier;
    const { data: note } = useQuery({
        queryKey: noteQueryKey(identifier),
        queryFn: () => getNote(identifier),
    });

    if (!note?.body) {
        return null;
    }

    return (
        <TitledGreyBox title={'Server notes'}>
            <p style={{ whiteSpace: 'pre-line' }}>{note.body.split('\n').slice(0, 3).join('\n')}</p>
        </TitledGreyBox>
    );
}
```

Aturan slot dari dokumen:

- **Nama slot yang tidak ada membuat extension tidak dimuat.** Galatnya muncul di konsol browser. Daftar nama lengkap ada di [referensi slot](referensi.md#slot).
- Beberapa extension di satu slot dirender sesuai urutan extension yang dikonfigurasi Panel, dengan dependensi lebih dulu.
- Bila komponen slot melempar error, hanya komponen itu yang disembunyikan. Pengguna melihat pemberitahuan dengan tombol coba lagi.

## Layar

Layar adalah halaman penuh. Deklarasikan dulu di `extension.json` pada `ui.screens`:

```json
"screens": [
    {
        "id": "notes",
        "area": "server",
        "path": "notes",
        "nav": { "label": "Notes" }
    }
]
```

Lalu daftarkan komponennya di `setup` dengan ID yang sama. Muat dengan `import` dinamis agar kodenya hanya diunduh saat halaman dibuka:

```tsx
screens.register('notes', () => import('./screens/NotesScreen'));
```

`area` menentukan lokasi halaman:

| Area | URL | Siapa yang bisa membuka |
|---|---|---|
| `server` | `/server/{server}/{path}` | pengguna dengan akses ke server |
| `account` | `/account/{path}` | pengguna yang sudah masuk |
| `admin` | `/panel/{path}` | administrator root |

- Layar dengan `nav` mendapat tautan di navigasi area-nya, setelah item bawaan Panel. Tanpa `nav`, layar punya URL tetapi tidak ada tautan.
- `nav.order` mengurutkan item extension. `nav.icon` (nama Lucide) dan `nav.badge` (teks pendek, maks 32 karakter) menambah ikon atau label.
- Di layar `server`, `permission` berupa daftar izin subuser. Layar dan tautannya hanya tampak bagi pengguna yang punya **minimal satu** izin tersebut. Rute backend tetap harus memeriksa izin sendiri.
- `path` tidak boleh bertabrakan dengan path Panel yang sudah ada di area itu. Path boleh berisi parameter bernama, mis. `logs/$date`, dan nilainya tersedia di `data.params.date`. `$id` dicadangkan. Item navigasi untuk path berparameter wajib mengisi `nav.params`.
- Setiap layar yang dideklarasikan di manifest **harus** didaftarkan di `setup`. Bila ada yang hilang atau ID-nya tidak cocok, extension tidak dimuat.

## Tab detail dan navigasi

Layar admin bisa menjadi tab di halaman detail node, server, pengguna, atau egg. Isi `parent` dan biarkan `area` tetap `admin`:

```json
{
    "id": "node-notes",
    "area": "admin",
    "parent": "admin.node",
    "path": "notes",
    "nav": { "label": "Notes", "order": 10, "icon": "file" }
}
```

Daftarkan `node-notes` dengan `screens.register` seperti biasa. URL-nya `/panel/nodes/{id}/notes`. Di dalam layar, `useCurrentResource()` mengembalikan `{ kind: 'admin.node', resource }`. Periksa `kind` sebelum membaca field resource.

`parent` yang diterima validator (tag beta.2): `admin.node`, `admin.server`, `admin.egg`, dan `admin.user`.

Untuk tautan, pakai `PanelLink`, dan `usePanelNavigate` untuk aksi. Keduanya memakai router Panel. Anda bisa menyebut layar extension alih-alih menyusun URL:

```tsx
import { PanelLink } from '@pterodactyl/sdk';

<PanelLink destination={{
    extension: 'server-notes',
    screen: 'node-notes',
    params: { id: String(nodeId) },
}}>
    Open notes
</PanelLink>
```

Untuk rute inti, pakai `destination={{ to: '/server/$id/files', params: { id: identifier } }}`. `usePanelLocation()` mengembalikan path, query, dan parameter saat ini.

## Kolom tabel

Untuk menambah kolom ke tabel node, server, atau egg asli, panggil `columns.register` di `setup`:

```tsx
columns.register('admin.nodes', {
    id: 'notes-host',
    label: 'Notes host',
    component: ({ data }) => <span>{data.attributes.fqdn}</span>,
});
```

Prop `data` bertipe sesuai tabel itu. Kolom muncul setelah kolom bawaan Panel, sesuai urutan extension. Setiap sel punya error boundary sendiri.

Tabel yang didukung: `admin.nodes`, `admin.servers`, dan `admin.eggs`. Setiap ID kolom berupa huruf kecil, angka, dan tanda hubung, dimulai huruf, maksimum 48 karakter.

## Penggantian komponen

> [!WARNING]
> Bagian ini menjelaskan **dokumen upstream**, bukan perilaku Panel beta.2 yang dikunci repositori ini. Di tag `v2.0.0-beta.2`, `components.replace`, `COMPONENT_NAMES`, dan `createComponentTestHost` tidak ada di SDK, dan validator tidak mengenal `ui.components`. Kunci `ui.components` yang dipakai extension kemungkinan diabaikan tanpa error. Itu inferensi dari kode validator, belum saya uji.

Penggantian komponen mengubah bagian tampilan Panel yang didukung. Panel tetap memegang query data, navigasi, izin, seleksi, menu, dan mutasi.

Deklarasikan nama komponen di manifest dengan batasan SDK:

```json
"requires": {
    "sdk": ">=2.0.0-beta.3 <3.0"
},
"ui": {
    "entry": "dist/client.js",
    "components": ["dashboard.serverCard", "server.files.details"]
}
```

Di `setup`, daftarkan implementasi untuk setiap komponen yang dideklarasikan, sebagai komponen atau importer lazy:

```tsx
export default definePterodactylExtension({
    setup({ components }) {
        components.replace('dashboard.serverCard', {
            load: () => import('./ServerCard'),
        });
        components.replace('server.files.details', {
            load: () => import('./FileDetails'),
        });
    },
});
```

Contoh `src/client/FileDetails.tsx` mengganti nama berkas dan mempertahankan ikon, ukuran, dan waktu dari Panel:

```tsx
import type { ComponentPartProps, ReplacementProps } from '@pterodactyl/sdk';

function FileName({ model }: ComponentPartProps<'server.files.details'>) {
    return <div className="flex-1 truncate font-medium text-foreground">{model.name}</div>;
}

export default function FileDetails({ Default }: ReplacementProps<'server.files.details'>) {
    return <Default parts={{ name: FileName }} />;
}
```

Aturan dari dokumen:

- Setiap penggantian menerima `model` hanya-baca, komponen `Default` asli, dan `parts` bertipe. `Default` menerima `className` dan penggantian sebagian `parts`.
- Komponen part didefinisikan di luar fungsi render agar identitasnya stabil.
- Part identitas kartu server asli memuat slot `dashboard.serverRow.name.after`. Sertakan part itu agar kontribusi slot tetap tampil.
- Area ini berada di dalam tautan inti. **Jangan** taruh tombol, tautan, input, atau elemen interaktif lain. Tambahkan aksi lewat slot aksi.
- Setiap komponen hanya boleh punya satu pemilik aktif. Konflik ditolak dan galatnya menyebut pemilik yang ada.

Perilaku muat dan cadangan:

- Area menampilkan skeleton selama implementasi dimuat.
- Bila `setup` atau pemuatan gagal, atau melebihi lima detik, tampilan asli dipakai. Import yang terlambat tidak bisa menggantinya di halaman yang sama.
- Kegagalan render mengembalikan tampilan asli dan menjaga state inti.
- Gunakan `Suspense` lokal untuk render async, dan `useExtensionAction` untuk callback. Panel tidak mengulang mutasi saat tampilan dikembalikan.

## Aksi file

Pengelola file punya slot untuk toolbar, aksi per baris, dan aksi file yang dipilih. Slot menerima server, direktori, file, nama yang dipilih, dan callback untuk memuat ulang atau mengubah seleksi. Aksi per baris juga menerima file-nya.

Contoh tombol toolbar yang memuat ulang daftar file asli:

```tsx
import { Button, useExtensionAction, type FileManagerSlotData } from '@pterodactyl/sdk';

function RefreshFiles({ data }: { data: FileManagerSlotData }) {
    const refresh = useExtensionAction('refresh files', () => data.refresh());
    return <Button disabled={data.isFetching} onClick={refresh}>Refresh files</Button>;
}

// In setup:
slots.register('server.files.toolbar', RefreshFiles);
```

- Bungkus handler klik async dengan `useExtensionAction` agar kegagalannya dikaitkan ke extension Anda.
- Untuk menulis, pakai mutasi file dari SDK. Periksa izin di **frontend dan backend**.

## Form asli

Untuk menggambar field yang dideklarasikan kelas `Fields` (lihat [backend](backend.md#field-tambahan-di-form-admin)), daftarkan komponen untuk form itu dengan `forms.extend`. Komponen menerima fungsi `field(name)` yang mengikat satu field ke form: `value`, callback `setValue`, `id` untuk label, dan `error` (pesan validasi dari penyimpanan terakhir sampai field diubah):

```tsx
import { definePterodactylExtension, Label, TextArea, type FormExtension } from '@pterodactyl/sdk';

const NoteField: FormExtension<{ body: string }, 'admin.server'> = ({ field }) => {
    const body = field('body');

    return (
        <div>
            <Label htmlFor={body.id}>Server note</Label>
            <TextArea id={body.id} value={body.value ?? ''} onChange={(event) => body.setValue(event.target.value)} />
            {body.error && <p className={'input-help error'}>{body.error}</p>}
        </div>
    );
};

export default definePterodactylExtension({
    setup({ forms }) {
        forms.extend('admin.server', NoteField);
    },
});
```

- Komponen juga menerima `values` (nilai tersimpan ditambah perubahan saat ini), `mode` (`'create'` atau `'edit'`), dan `resource` (resource tersimpan saat mengedit).
- Beri tipe `values` lewat parameter pertama `FormExtension`, agar `field` hanya menerima nama field Anda.
- Form yang didukung: `admin.user`, `admin.server`, `admin.node`, `admin.egg`, `admin.location`, `admin.mount`, dan `admin.database_host`. Setiap form mencakup halaman create dan edit. Untuk server, halaman edit adalah tab **Details**.
- Field hanya tampil bila backend mendaftarkan kelas `Fields` untuk model itu dan administrator boleh mengubahnya. Saat mengedit, komponen juga dihilangkan bila nilai tersimpan tidak bisa dibaca, sehingga penyimpanan tidak menimpa data.

Slot `panel.users.detail.form` berbeda. Ia dirender di dalam form detail pengguna dan menerima `form` asli, sehingga Anda bisa menggambar ulang field pengguna bawaan atau menambah validator. Slot ini **tidak** bisa menambah field baru:

```tsx
slots.register('panel.users.detail.form', ({ data }) => (
    <data.form.AppField
        name="username"
        validators={{ onSubmit: ({ value }) => value.length < 3 ? 'Use at least three characters.' : undefined }}
    >
        {(field) => <field.TextField label="Managed username" />}
    </data.form.AppField>
));
```

Slot `server.startup.form` menerima konfigurasi startup saat ini, status pending, dan callback `setDockerImage` yang memeriksa izin pengguna serta menjaga cache asli tetap mutakhir.

## Lihat juga

- [Data dan gaya](data-dan-gaya.md): hook data, panggilan API, komponen, tema.
- [Referensi slot](referensi.md#slot) untuk daftar lengkap nama dan data slot.
- [Kompatibilitas](kompatibilitas.md) untuk fitur yang belum ada di beta.2.

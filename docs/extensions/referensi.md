# Referensi extension: manifest, command, API backend, SDK, slot

> **Jenis:** Referensi · **Per:** 2026-10-20 · **Sumber utama:** [Extension Reference](https://docs.pterodactyl.io/v2/extensions/reference) (`reference.mdx`), dicocokkan dengan kode tag `v2.0.0-beta.2` · **Kembali ke:** [indeks extension](README.md)

Halaman ini mendaftar semua yang tersedia untuk extension. Setiap tabel bertanda sumber. Bila dokumen dan kode berbeda, kode beta.2 yang berlaku untuk Panel yang dikunci repositori ini. Perbedaan yang sudah diketahui ditandai **⚠** dan dirangkum di [kompatibilitas](kompatibilitas.md).

Legenda:

- **⚠ beta.2:** fitur ini ada di dokumen upstream tetapi tidak ditemukan di tag `v2.0.0-beta.2`.
- **(kode):** ada di kode beta.2 tetapi tidak tercantum di dokumen upstream.

## Manifest

`extension.json` mendukung kunci berikut. Sumber: tabel di dokumen, aturan dari `ExtensionManifestValidator.php` dan `ExtensionManifest.php` (tag beta.2).

| Kunci | Wajib | Tipe dan batas | Keterangan |
|---|---|---|---|
| `id` | ya | `^[a-z][a-z0-9-]{0,47}$`, maks 48 | harus sama dengan nama direktori. `pterodactyl`, `panel`, `core`, dan `classic` dicadangkan (**`classic` hanya di kode**) |
| `name` | ya | string | nama tampilan |
| `version` | ya | string, maks 64 | |
| `type` | tidak | `extension` atau `theme` | **(kode)** `theme` mengaktifkan kunci `theme` |
| `$schema` | tidak | path | biasanya `./node_modules/@pterodactyl/sdk/manifest.schema.json` |
| `description`, `author` | tidak | string | tampil di area admin |
| `requires.panel` | tidak | constraint Composer | dibandingkan dengan `app.version` (`canary` = `2.0.0-dev`) |
| `requires.sdk` | tidak | constraint Composer | **wajib** bila `ui.views` dipakai (kode). Dokumen menyebut "dengan penggantian komponen" (⚠ beta.2) |
| `requires.php` | tidak | constraint Composer | |
| `requires.extensions` | tidak | peta ID → constraint, maks 64 | setiap dependensi harus aktif |
| `icon` | tidak | nama Lucide (`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`) atau path `.png`, `.jpg`, `.jpeg`, `.webp`; maks 255 karakter | lihat [ikon](membangun.md#ikon) |
| `provider` | tidak | nama kelas, memperluas `ExtensionProvider` | |
| `autoload` | tidak | peta PSR-4 namespace → direktori | namespace tidak boleh tumpang tindih dengan Panel atau extension lain |
| `routes.root` | tidak | daftar maks 8 prefiks, masing-masing `^[a-z][a-z0-9-]{0,47}$` | **(kode)** prefiks yang dipakai Panel atau berkas di direktori publik ditolak |
| `ui.entry` | dengan `ui` | harus tepat `dist/client.js` | |
| `ui.mode` | tidak | hanya `native` | |
| `ui.prefix` | dengan kelas Tailwind | `^[a-z]{2,12}$`, unik antar extension aktif | nama varian Tailwind dan nama yang dicadangkan ditolak. Dilarang untuk tema |
| `ui.screens` | tidak | daftar maks 64 | lihat [kunci layar](#kunci-layar) |
| `ui.views` | tidak | daftar nama view, mis. `server.power` | **(kode)** nama di beta.2 untuk penggantian komponen. Dilarang untuk tema |
| `ui.components` | tidak | daftar nama komponen | ⚠ beta.2: nama di dokumen upstream, tidak dikenal validator beta.2 |
| `theme` | hanya tema | objek `extends`, `stylesheet`, `schemes`, `settings` | **(kode)** lihat [tema](data-dan-gaya.md#tema) |

### Kunci layar

Setiap entri `ui.screens`:

| Kunci | Wajib | Keterangan |
|---|---|---|
| `id` | ya | `^[a-z][a-z0-9-]*$`, maks 48, unik |
| `area` | ya | `server`, `account`, atau `admin` |
| `parent` | tidak | `admin.node`, `admin.server`, `admin.egg`, `admin.user`. Hanya dengan `area: "admin"` |
| `path` | ya | segmen statis pertama, lalu segmen statis atau parameter `$nama`. `$id` dicadangkan. Maks 255 |
| `nav.label` | dengan `nav` | maks 100 |
| `nav.exact` | tidak | sorot hanya pada kecocokan path persis |
| `nav.params` | untuk navigasi berparameter | harus berisi tepat parameter path layar (kode) |
| `nav.order` | tidak | bilangan bulat -10000 sampai 10000, bawaan 0 |
| `nav.group` | tidak | maks 100, tooltip |
| `nav.badge` | tidak | maks 32 |
| `nav.icon` | tidak | nama Lucide, maks 64 |
| `permission` | tidak | hanya `server`. Daftar izin subuser, minimal satu |
| `when.eggTags`, `when.eggFeatures` | tidak | hanya `server`. Objek `{ "any": [...], "all": [...] }`, masing-masing 1 sampai 32 nilai |
| `when.match` | tidak | `all` (bawaan) atau `any`. Hanya bila kedua aturan egg ada |
| `when.runtime` | tidak | `true` menyembunyikan layar sampai predikat `visible` bernilai benar |

Kode menolak `when` tanpa aturan egg dan tanpa `"runtime": true`, serta `when.match` tanpa dua aturan egg (`ExtensionManifestValidator::validateScreenCondition`).

Prefiks URL layar (dokumen): `account` → `/account`; `server` → `/server/{id}`; `admin` → `/panel`; `admin.node` → `/panel/nodes/{id}`; `admin.server` → `/panel/servers/{id}`; `admin.user` → `/panel/users/{id}`; `admin.egg` → `/panel/eggs/{eggId}`.

## Command Artisan

Signature diambil dari atribut `#[Signature]` di kode beta.2. Dokumen upstream mendaftar lebih sedikit opsi.

| Command | Argumen dan opsi (kode beta.2) | Keterangan |
|---|---|---|
| `p:extension:make {id}` | `--name`, `--description`, `--author`, `--prefix`, `--no-ui`, `--theme` ⁽ᵏ⁾, `--css-only` ⁽ᵏ⁾, `--extends` ⁽ᵏ⁾, `--out`, `--force` | kerangka paket. ⁽ᵏ⁾ = hanya di kode |
| `p:extension:install {path}` | `--enable`, `--replace` ⁽ᵏ⁾ | `path` berupa `.pteroext`, `.zip`, direktori, atau URL install bertanda tangan ⁽ᵏ⁾. `--replace` menimpa extension dengan ID sama tanpa bertanya ⁽ᵏ⁾ |
| `p:extension:enable {id}` | | publikasikan frontend, jalankan migrasi, aktifkan |
| `p:extension:disable {id}` | | nonaktifkan; file dan data tetap |
| `p:extension:remove {id}` | | hapus file dan aset; tabel dan pengaturan tetap |
| `p:extension:list` | | daftar ID, Name, Version, UI, State, Error |
| `p:extension:doctor {path}` | `path` | periksa paket yang belum dipasang |
| `p:extension:dev {path}` | `--watch`, `--enable` | bangun dan publikasikan; `--watch` memantau ulang |
| `p:extension:types {path}` | `--output` ⁽ᵏ⁾ | hasilkan tipe TypeScript. Bawaan `src/client/extension-types.ts`; untuk tema `src/theme-types.ts` (kode) |
| `p:extension:pack {path}` | `--output`, `--force`, `--sourcemaps` ⁽ᵏ⁾ | kemas `.pteroext`. Bawaan `{id}-{version}.pteroext` |

Perintah tema (ada di tag beta.2, tetapi tidak ada di dokumen referensi extension):

| Command | Signature |
|---|---|
| `p:theme:list` | `p:theme:list` |
| `p:theme:activate {id}` | `{id : The theme identifier, or "classic".}` |
| `p:theme:reset` | `p:theme:reset` |

Dokumen upstream membahas `p:theme:apply` dan `p:theme:reset`, tetapi `p:theme:apply` tidak ada di tag beta.2. Lihat [data dan gaya](data-dan-gaya.md#tema).

## Metode provider

`Pterodactyl\Extensions\ExtensionProvider` (kode beta.2 memastikan keberadaan `registerRootRoutes`, `registerFields`, `listenToServerOperations`, `registerWebRoutes`, dan `registerHeadTags`):

| Metode | Keterangan |
|---|---|
| `registerApiRoutes()` | memuat `routes/client.php`, `server.php`, `admin.php`, dan `application.php` bila ada |
| `loadExtensionMigrations()` | mendaftarkan `database/migrations` |
| `registerSettings($definition)` | mendaftarkan pengaturan |
| `settings()` | penyimpanan key-value extension |
| `registerPermissions($description, $keys)` | izin di bawah `ext.{id}.{key}` |
| `registerFields($model, $fields)` | menambah field ke form admin model |
| `listenToServerOperations($listener)` | listener hasil operasi server |
| `loadExtensionViews()` | view Blade di `resources/views`, sebagai `ext-{id}::view` |
| `loadExtensionTranslations()` | terjemahan di `resources/lang`, sebagai `ext-{id}::key` |
| `registerRootRoutes($path, $prefix = null)` | rute di akar URL, sesuai `routes.root` |
| `registerHeadTags(...)` | tag kepala halaman (**(kode)**; tidak dibahas di dokumen referensi) |
| `id()` | ID extension |
| `extensionPath(...$parts)` | path absolut di dalam direktori extension |

### Helper rute

| Metode | Prefiks URL | Akses |
|---|---|---|
| `registerClientApiRoutes($path)` | `/api/client/extensions/{id}` | pengguna yang masuk dan kunci Client API |
| `registerServerApiRoutes($path)` | `/api/client/servers/{server}/extensions/{id}` | pengguna dengan akses ke server |
| `registerAdminApiRoutes($path)` | `/api/admin/extensions/{id}` | administrator root |
| `registerApplicationApiRoutes($path)` | `/api/application/extensions/{id}` | administrator root dan kunci Application API |
| `registerAuthenticatedWebRoutes($path)` | `/extensions/{id}` | pengguna yang masuk |
| `registerWebRoutes($path)` | `/extensions/{id}` | siapa saja. Tambahkan middleware sendiri |
| `registerRootRoutes($path, $prefix = null)` | `/{prefix}` | siapa saja, dibatasi `extensions.root_routes_per_minute` (bawaan 120) per klien |

Nama rute diberi awalan `extensions.{id}.` diikuti `client.`, `server.`, `admin.`, `application.`, `web.`, atau `root.{prefix}.`. Path `/api/admin/extensions/{id}/settings` dicadangkan untuk Panel.

## Pengaturan

`ExtensionSettingDefinition::make($key, $input, $default, $rules)`:

| Metode | Keterangan |
|---|---|
| `label($label)` | label form, bawaannya nama input dalam huruf judul |
| `help($text)` | teks bantuan di bawah field |
| `field($type, $options = [])` | tipe kontrol. Dokumen: `text`, `password`, `number`, `toggle`, `select`. **(kode)** juga `color`, `textarea`, `multiselect`, `list`, `file` |
| `frontend()` | kirim ke bundel sebagai `config`, bisa dibaca semua pengguna yang masuk |
| `frontendType($type)` | `string`, `number`, `boolean`, `array`, `object`, `null`, atau `json` (bawaan). Dicek sebelum nilai diekspos |
| `secret()` | enkripsi, kontrol password, dikembalikan kosong ke form. Tidak bisa dikombinasikan dengan `frontend()`. Pembaruan kosong mempertahankan nilai |
| `normalizeUsing($callback)` | ubah nilai saat dibaca dan disimpan |
| `publicUsing($callback)` | ubah nilai sebelum ditampilkan, mis. menyamarkan |

**(kode)** Aturan tambahan dari `ExtensionSettingDefinition`:

- Tipe `color`, `textarea`, `multiselect`, `list`, dan `file` tidak bisa menjadi rahasia.
- Tipe `file` menerima daftar MIME dan batas `maxKilobytes` (bawaan 1024, maksimum `ExtensionSettingFiles::MAX_KILOBYTES`), dan nilai bawaannya hanya URL atau `null`.
- Nilai harus berupa skalar JSON atau array, bersarang maksimal 10 tingkat.

Penyimpanan (`settings()`):

| Metode | Keterangan |
|---|---|
| `get($key, $default = null)` | baca, mendekripsi bila rahasia |
| `set($key, $value)` | simpan nilai JSON biasa |
| `setSecret($key, $value)` | simpan nilai terenkripsi |
| `setMany($values)` | simpan peta nilai biasa sekaligus |
| `setManySecrets($values, $secretKeys)` | simpan peta, mengenkripsi kunci di `$secretKeys` |
| `forget($key)` | hapus |
| `all()` | baca semua nilai di cakupan ini |
| `getByPrefix($prefix)` / `forgetByPrefix($prefix)` | baca atau hapus kunci berawalan |
| `forUser($user)`, `forServer($server)`, `for($model)` | cakupan per model tersimpan |
| `fields($model)` | nilai field form untuk model, bila kelas `Fields` tidak punya `values` dan `save` |

Cakupan global, per model, dan nilai field form terpisah. Menghapus model ikut menghapus pengaturan bercakupannya.

## Izin

Izin extension didaftarkan dengan `registerPermissions($description, ['read' => 'Read notes.'])` dan menjadi `ext.{id}.read`. Wildcard `ext.{id}.*` hanya mencakup extension itu.

Izin inti (dokumen):

| Grup | Izin |
|---|---|
| Console | `websocket.connect`, `control.console`, `control.start`, `control.stop`, `control.restart` |
| Subusers | `user.create`, `user.read`, `user.update`, `user.delete` |
| Files | `file.create`, `file.read`, `file.read-content`, `file.update`, `file.delete`, `file.archive`, `file.sftp` |
| Backups | `backup.create`, `backup.read`, `backup.delete`, `backup.download`, `backup.restore` |
| Network | `allocation.read`, `allocation.create`, `allocation.update`, `allocation.delete` |
| Startup | `startup.read`, `startup.update`, `startup.docker-image` |
| Databases | `database.create`, `database.read`, `database.update`, `database.delete`, `database.view_password` |
| Schedules | `schedule.create`, `schedule.read`, `schedule.update`, `schedule.delete` |
| Settings | `settings.rename`, `settings.reinstall` |
| Activity | `activity.read` |

Pemilik server dan administrator root lolos semua pemeriksaan.

## Field form

`registerFields($model, $fields)`:

| Metode | Dipanggil | Keterangan |
|---|---|---|
| `rules()` | setiap penyimpanan yang memvalidasi extension ini, termasuk pembuatan | aturan per field, hanya untuk nilai extension ini |
| `values($model)` | saat resource dikembalikan | nilai saat ini |
| `save($model, $values)` | dalam transaksi penulisan, setelah baris model ditulis | simpan. Nama parameter harus `$values` |
| `authorize()` | sebelum nilai diterima atau dikembalikan | boleh atau tidak |
| `secrets()` | saat disimpan dan dikembalikan | dienkripsi, dikembalikan `********` |
| `attributes()`, `messages()` | saat validasi | nama dan pesan error |

Model yang didukung:

| Model | Form admin | Halaman |
|---|---|---|
| `Pterodactyl\Models\User` | `admin.user` | buat pengguna, detail pengguna |
| `Pterodactyl\Models\Server` | `admin.server` | buat server, tab Details |
| `Pterodactyl\Models\Node` | `admin.node` | buat node, tab Settings |
| `Pterodactyl\Models\Egg` | `admin.egg` | buat egg, tab Configuration |
| `Pterodactyl\Models\Location` | `admin.location` | dialog lokasi baru, detail lokasi |
| `Pterodactyl\Models\Mount` | `admin.mount` | buat mount, detail mount |
| `Pterodactyl\Models\DatabaseHost` | `admin.database_host` | buat host database, detail host database |

Perilaku: pendaftaran ditolak untuk model tak didukung, kelas yang tidak memperluas `Fields`, hanya satu dari `values`/`save`, atau model yang didaftarkan dua kali. Galat validasi berbentuk `extensions.{id}.{field}`. Extension yang `values`-nya melempar akan menghasilkan `422` di bawah `extensions.{id}`. `authorize` yang menolak menghasilkan `403`. `GET /api/admin/extensions/forms` mendaftar form yang punya field dari extension aktif.

Atribut `#[ApplicationApi]` (`Pterodactyl\Extensions\Attributes\ApplicationApi`) membuka nilai di endpoint user, node, lokasi, dan server pada Application API.

## Event

Namespace `Pterodactyl\Events\Extensions`:

| Event | Dikirim |
|---|---|
| `ExtensionInstalling` | sebelum pemasangan. Juga `$source` |
| `ExtensionInstalled` | sesudah pemasangan |
| `ExtensionEnabling` | sebelum aktivasi |
| `ExtensionEnabled` | sesudah aktivasi dan migrasi |
| `ExtensionDisabling` | sebelum nonaktivasi |
| `ExtensionDisabled` | sesudah nonaktivasi |
| `ExtensionRemoving` | sebelum penghapusan |
| `ExtensionRemoved` | sesudah penghapusan. Hanya `$identifier` |
| `ExtensionLoadFailed` | saat provider melempar exception. `$identifier`, `$phase`, `$reason`, `$exception` |

`Pterodactyl\Events\Server\OperationCompleted` (untuk `listenToServerOperations`):

| Properti | Nilai |
|---|---|
| `serverUuid` | UUID server |
| `operation` | `provision`, `install`, `reinstall`, `backup` |
| `successful` | hasil |
| `resourceUuid` | UUID backup untuk backup; UUID server untuk operasi lain |

## Progres pekerjaan

`Pterodactyl\Services\Extensions\ExtensionJobProgress`:

| Metode | Keterangan |
|---|---|
| `begin($extension, $user, $server = null, $permission = null)` | buat snapshot dengan UUID, status `running`, persen 0 |
| `update($extension, $id, $percent, $message = '', $status = 'running')` | persen 0 sampai 100, tidak boleh turun; pesan maks 1000 karakter; `completed` menetapkan 100 |
| `find($extension, $id)` | baca snapshot; `null` bila tidak ada atau kedaluwarsa. Tanpa otorisasi |
| `visible($extension, $id, $user, $server = null)` | baca setelah memeriksa subjek dan akses saat ini. Tidak tersedia = 404 |

Status: `running`, `completed`, `failed`. Setiap pembaruan menaikkan `sequence`. Payload frontend berisi `id`, `extension`, `status`, `percent`, `message`, `sequence`, dan `updated_at`.

| Endpoint GET | Subjek |
|---|---|
| `/api/client/extension-progress/{extension}/{job}` | job pengguna |
| `/api/client/servers/{server}/extension-progress/{extension}/{job}` | job server |

Retensi: `extensions.progress_retention_seconds` (bawaan 3600 detik sejak pembaruan terakhir, sesuai `config/extensions.php`). Web request dan worker harus memakai cache store yang sama.

## Konfigurasi environment

| Variabel | Bawaan | Keterangan |
|---|---|---|
| `PTERODACTYL_EXTENSIONS_ENABLED` | `true` | `false` mematikan semua extension tanpa menghapusnya |
| `PTERODACTYL_EXTENSIONS_DIRECTORY` | `extensions` di direktori Panel | lokasi pemasangan |
| `PTERODACTYL_EXTENSIONS_URL_INSTALLS_ENABLED` | `true` | pemasangan dari URL bertanda tangan (**(kode)**) |
| `PTERODACTYL_EXTENSIONS_FILES_DISK` | `local` | disk untuk berkas yang diunggah pengaturan `file` (**(kode)**). Disk publik ditolak |

Dari `config/extensions.php` (tag beta.2): `sdk_version` = `2.0.0-beta.6`; `head_tags_cache_seconds` = 60; `root_routes_per_minute` = 120; `progress_retention_seconds` = 3600; `assets_directory` = `public/assets/extensions`.

## SDK frontend

Impor dari `@pterodactyl/sdk`. Di Panel, paket ini disediakan lewat import map sehingga tidak ikut dibundel.

Dua cara mendefinisikan entri: `definePterodactylExtension({ setup })` atau `defineConfiguredExtension(parseConfig, { setup })`. `setup` bersifat sinkron.

### Konteks setup

| Properti | Keterangan |
|---|---|
| `meta` | `{ id, version }` |
| `config` | nilai pengaturan frontend |
| `slots.register(name, component)` | render komponen di slot |
| `screens.register(id, importer, options?)` | pasang komponen ke layar yang dideklarasikan. `options.visible` untuk `when.runtime`, `options.badge` untuk badge navigasi |
| `columns.register(name, column)` | kolom bertipe untuk tabel admin |
| `components.replace(name, replacement)` | ⚠ beta.2: penggantian tampilan untuk nama di `ui.components` |
| `forms.extend(form, component)` | gambar field extension di form admin |

### Penggantian komponen (⚠ beta.2)

Dokumen upstream menyebut empat nama, yang tidak ada di SDK tag beta.2:

| Nama | Model | Bagian asli |
|---|---|---|
| `dashboard.serverCard` | `ServerCardModel` | `identity`, `address`, `metrics` |
| `server.files.details` | `FileDetailsModel` | `icon`, `name`, `size`, `modified` |
| `server.files.editor` | `FileEditorModel` | `notice`, `editor`, `language`, `actions` |
| `server.files.manager` | `FileManagerModel` | `toolbar`, `list`, `selection` |

Dokumen juga mendaftar `COMPONENT_NAMES`, `ReplacementProps`, `ComponentPartProps`, dan `createComponentTestHost`. Di tag beta.2, `COMPONENT_NAMES` dan `createComponentTestHost` tidak ditemukan dalam sumber SDK yang diambil. Penjelasan lengkap di [frontend](frontend.md#penggantian-komponen).

Batas waktu muat menurut dokumen: lima detik. Penggantian yang gagal memakai tampilan asli.

### Hook

| Hook | Mengembalikan |
|---|---|
| `useCurrentUser()` | pengguna yang masuk |
| `useSiteSettings()` | nama Panel, locale, pengaturan reCAPTCHA |
| `useCurrentServer(select?)` | server saat ini, atau `undefined` |
| `useCurrentServerRequired(message?)` | server saat ini; melempar di halaman tanpa server |
| `useCurrentServerUuid()` | UUID server saat ini |
| `useCurrentServerPermissions()` | izin pengguna di server (`['*']` untuk pemilik) |
| `useServerPermission(permission, matchAny?)` | apakah punya izin (atau salah satu / semua dari daftar) |
| `usePermissions(permissions)` | satu boolean per izin |
| `useServerWebsocketEvent(event, callback)` | event live server, mis. `SocketEvent.STATUS`, `SocketEvent.CONSOLE_OUTPUT`, `backup completed:{uuid}` |
| `useCurrentResource()` | `{ kind, resource }` di halaman detail admin, atau `null` |
| `useExtensionAction(name, callback)` | handler yang galatnya dikaitkan ke extension |
| `useExtensionTranslation(group = 'messages')` | `{ locale, ready, t }` |
| `useExtensionJobProgress(job, { serverUuid }?)` | hasil query job; polling tiap 1,5 detik menurut dokumen. Nilai ini tidak saya verifikasi di kode (runtime SDK tidak ada di sumber yang diambil; tipenya ada di `packages/sdk/types/sdk/progress.d.ts`) |

### Data server dan mutasi

Factory query: `serverQueryOptions(id)`, `serverFilesQueryOptions(uuid, directory)`, `serverFileContentQueryOptions(uuid, file)`, `serverStartupQueryOptions(uuid)`, `serverBackupsQueryOptions(uuid, page = 1)`.

Hook: `useServerFiles`, `useServerFileContent`, `useServerStartup`, `useServerBackups`.

`invalidateServerData(uuid, domains)`: domain `server`, `files`, `fileContent`, `startup`, `backups`.

Mutasi (masing-masing mengembalikan `isPending`, `error`, `data`, `mutateAsync(input)`, `reset()`):

| Hook | Input |
|---|---|
| `useCreateServerDirectory(uuid)` | `{ directory, name }` |
| `useRenameServerFiles(uuid)` | `{ directory, files: [{ from, to }] }` |
| `useDeleteServerFiles(uuid)` | `{ directory, files: string[] }` |
| `useWriteServerFile(uuid)` | `{ file, content }` |
| `useUpdateServerStartupVariable(uuid)` | `{ key, value }` |
| `useSetServerDockerImage(uuid)` | `{ image }` |
| `useCreateServerBackup(uuid)` | `{ name?, ignored?, isLocked }` |

### Navigasi

| Ekspor | Keterangan |
|---|---|
| `PanelLink` | tautan dengan `destination` dan `exact` opsional |
| `usePanelNavigate()` | fungsi navigasi |
| `usePanelLocation()` | `RouteSlotData` saat ini |
| `resolvePanelDestination(destination)` | ubah tujuan menjadi `pathname`, query, hash, dan `replace` |

Tujuan inti: `{ to, params?, search?, hash?, replace? }`. Tujuan extension: `{ extension, screen, params?, search?, hash?, replace? }`.

### Kolom tabel

`columns.register(name, { id, label, component })`:

| Nama | Data komponen |
|---|---|
| `admin.nodes` | resource node asli |
| `admin.servers` | resource server asli |
| `admin.eggs` | resource egg asli |

### Komponen

| Komponen | Keterangan |
|---|---|
| `Button` | tombol. Juga `Button.Text` dan `Button.Danger`. Mendukung `isLoading`, `size`, `color`, `isSecondary` |
| `Input`, `TextArea` | field teks |
| `Select` | menu pilih, tunggal atau ganda |
| `Checkbox`, `Switch` | kotak centang dan sakelar |
| `Label` | label form |
| `Form`, `useAppForm` | form di atas TanStack Form |
| `Dialog` | dialog, termasuk `Dialog.Confirm` |
| `Alert` | pemberitahuan: `success`, `info`, `warning`, `danger` |
| `ContentBox`, `TitledGreyBox` | kotak konten |
| `PageContentBlock`, `ServerContentBlock` | pembungkus halaman yang mengatur judul. Gunakan `ServerContentBlock` di layar server |
| `Spinner` | indikator muat |
| `Icon` | ikon Lucide |
| `Can` | render anak hanya bila punya izin |
| `CopyOnClick` | salin teks saat diklik |
| `ScreenBlock`, `ServerError`, `NotFound` | pesan layar penuh |
| `Table` | tabel asli dengan `rows`, `columns`, `keyOf`, `emptyState` |
| `Tooltip` | tooltip bertema |
| `DropdownMenu`, `DropdownMenuItem`, `ContextDropdownMenu` | menu |
| `Pagination` | pemilih halaman |
| `PanelLink` | tautan dengan tujuan bertipe |

`toast` untuk notifikasi.

### HTTP

| Ekspor | Keterangan |
|---|---|
| `http` | instance Axios Panel, sudah terautentikasi |
| `httpErrorToHuman(error)` | pesan error yang bisa dibaca |
| `queryClient` | TanStack Query client Panel |
| `client` dari `@pterodactyl/sdk/api` | transport bersama untuk klien hasil generate |

## Build dan pengujian

| Entri paket | Isi |
|---|---|
| `@pterodactyl/sdk/vite` | `defineExtensionConfig({ entry, outDir?, plugins? })`. `entry` wajib, `outDir` bawaan `dist` |
| `@pterodactyl/sdk/testing` | `createExtensionTestHost(options?)`, `createTestServer(options?)`, `createTestServerCard(options?)`, `createTestFileDetails`, `createTestFileEditor`, `createTestFileManager`, `createTestFileManagerEntry`; `createComponentTestHost` ⚠ beta.2 |
| `@pterodactyl/sdk/vitest` | `pterodactylTestAliases`, `pterodactylTestSetup`, `pterodactylTestDirectory` |
| `@pterodactyl/sdk/openapi` | `externalizeExtensionApi(directory)` |
| `@pterodactyl/sdk/theme.css` | pemetaan Tailwind ke token desain Panel. Impor bersama tema dan utilitas, tanpa preflight |
| `@pterodactyl/sdk/manifest.schema.json` | pelengkapan `extension.json` di editor |

Opsi test host: `extensionId`, `prefix`, `path`, `user`, `siteSettings`, `server`, `resource`. Host menyediakan `Wrapper`, `queryClient`, `navigate`, `emitWebsocket`, `setConnected`, dan `dispose()`.

`createTestServer` menerima `identifier`, `uuid`, `name`, `owner`, `permissions`, `status`.

## Slot

Slot adalah tempat bernama di halaman Panel tempat extension merender komponen. Daftarkan dengan `slots.register(name, component)`. Kolom `data` menunjukkan prop `data` komponen. Nama yang tidak ada membuat extension gagal dimuat.

### Kontrak data slot

| Kontrak | Isi dan kegunaan |
|---|---|
| `RouteSlotData` | `pathname`, `search`, `params` |
| `SdkServer` | server saat ini, field resource di `attributes` |
| `SubuserPermissionsSlotData` | `mode`, `selectedPermissions`, `editablePermissions`, `disabled`, `setPermissions` |
| `FileManagerSlotData` | `server`, `directory`, `files`, `selectedFiles`, `isFetching`, `setSelectedFiles(names)`, `refresh()` |
| `FileRowSlotData` | field pengelola file, plus `file` |
| `StartupFormSlotData` | `server`, `configuration`, `isPending`, `canChangeDockerImage`, `setDockerImage(image)`, `refresh()` |
| `ExtensionResourceContext` | `kind` dan `resource` asli yang cocok |
| `AdminUserFormSlotData` | `kind: 'admin.user'`, `resource`, `form` asli |

Field form pengguna asli: `email`, `username`, `nameFirst`, `nameLast`, `password`, `rootAdmin`, `language`.

### Slot navigasi

| Slot | Lokasi | Posisi | `data` |
|---|---|---|---|
| `nav.items.before` | bilah navigasi atas | sebelum | tidak ada |
| `nav.items.after` | bilah navigasi atas | sesudah | tidak ada |

### Slot autentikasi

| Slot | Lokasi | Posisi | `data` |
|---|---|---|---|
| `auth.login.before` | halaman login | sebelum | `RouteSlotData` |
| `auth.login.after` | halaman login | sesudah | `RouteSlotData` |
| `auth.login.form.after` | form login, di bawah tombol Login | sesudah | `RouteSlotData` |
| `auth.checkpoint.before` | halaman dua faktor | sebelum | `RouteSlotData` |
| `auth.checkpoint.after` | halaman dua faktor | sesudah | `RouteSlotData` |
| `auth.password.before` | halaman lupa kata sandi | sebelum | `RouteSlotData` |
| `auth.password.after` | halaman lupa kata sandi | sesudah | `RouteSlotData` |
| `auth.passwordReset.before` | halaman atur ulang kata sandi | sebelum | `RouteSlotData` |
| `auth.passwordReset.after` | halaman atur ulang kata sandi | sesudah | `RouteSlotData` |

### Slot dashboard

| Slot | Lokasi | Posisi | `data` |
|---|---|---|---|
| `dashboard.before` | dashboard | sebelum | tidak ada |
| `dashboard.after` | dashboard | sesudah | tidak ada |
| `dashboard.serverRow.before` | setiap server di dashboard | sebelum | `SdkServer` |
| `dashboard.serverRow.after` | setiap server di dashboard | sesudah | `SdkServer` |
| `dashboard.serverRow.name.after` | nama setiap server di dashboard | sesudah | `SdkServer` |
| `dashboard.serverRow.metrics.after` | pemakaian sumber daya setiap server | sesudah | `SdkServer` |

### Slot akun

| Slot | Lokasi | Posisi | `data` |
|---|---|---|---|
| `account.navigation.before` | navigasi akun | sebelum | tidak ada |
| `account.navigation.after` | navigasi akun | sesudah | tidak ada |
| `account.overview.before` | ikhtisar akun | sebelum | tidak ada |
| `account.overview.after` | ikhtisar akun | sesudah | tidak ada |
| `account.api.before` | halaman kunci API | sebelum | `RouteSlotData` |
| `account.api.after` | halaman kunci API | sesudah | `RouteSlotData` |
| `account.ssh.before` | halaman kunci SSH | sebelum | `RouteSlotData` |
| `account.ssh.after` | halaman kunci SSH | sesudah | `RouteSlotData` |
| `account.activity.before` | halaman aktivitas | sebelum | `RouteSlotData` |
| `account.activity.after` | halaman aktivitas | sesudah | `RouteSlotData` |

### Slot server

| Slot | Lokasi | Posisi | `data` |
|---|---|---|---|
| `server.navigation.before` | navigasi server | sebelum | `SdkServer` |
| `server.navigation.after` | navigasi server | sesudah | `SdkServer` |
| `server.console.before` | halaman konsol | sebelum | `SdkServer` |
| `server.console.power.before` | tombol daya konsol | sebelum | `SdkServer` |
| `server.console.power.after` | tombol daya konsol | sesudah | `SdkServer` |
| `server.console.after` | halaman konsol | sesudah | `SdkServer` |
| `server.files.before` | pengelola file | sebelum | tidak ada |
| `server.files.after` | pengelola file | sesudah | tidak ada |
| `server.files.toolbar` | toolbar pengelola file | di dalam | `FileManagerSlotData` |
| `server.files.rowActions` | baris file dan menu konteks | aksi | `FileRowSlotData` |
| `server.files.selectionActions` | bilah aksi file terpilih | aksi | `FileManagerSlotData` |
| `server.files.editor.before` | editor file | sebelum | `RouteSlotData` |
| `server.files.editor.after` | editor file | sesudah | `RouteSlotData` |
| `server.databases.before` | halaman database | sebelum | `RouteSlotData` |
| `server.databases.after` | halaman database | sesudah | `RouteSlotData` |
| `server.schedules.before` | halaman jadwal | sebelum | `RouteSlotData` |
| `server.schedules.after` | halaman jadwal | sesudah | `RouteSlotData` |
| `server.schedules.detail.before` | detail jadwal | sebelum | `RouteSlotData` |
| `server.schedules.detail.after` | detail jadwal | sesudah | `RouteSlotData` |
| `server.users.before` | halaman subuser | sebelum | `RouteSlotData` |
| `server.users.after` | halaman subuser | sesudah | `RouteSlotData` |
| `server.users.create.before` | buat subuser | sebelum | `RouteSlotData` |
| `server.users.create.after` | buat subuser | sesudah | `RouteSlotData` |
| `server.users.permissions.before` | editor izin subuser | sebelum | `SubuserPermissionsSlotData` |
| `server.backups.before` | halaman backup | sebelum | `RouteSlotData` |
| `server.backups.after` | halaman backup | sesudah | `RouteSlotData` |
| `server.network.before` | halaman jaringan | sebelum | `RouteSlotData` |
| `server.network.after` | halaman jaringan | sesudah | `RouteSlotData` |
| `server.startup.before` | halaman startup | sebelum | `RouteSlotData` |
| `server.startup.after` | halaman startup | sesudah | `RouteSlotData` |
| `server.startup.form` | konfigurasi startup | di dalam | `StartupFormSlotData` |
| `server.settings.before` | halaman pengaturan | sebelum | `RouteSlotData` |
| `server.settings.after` | halaman pengaturan | sesudah | `RouteSlotData` |
| `server.activity.before` | halaman aktivitas | sebelum | `RouteSlotData` |
| `server.activity.after` | halaman aktivitas | sesudah | `RouteSlotData` |

### Slot admin

| Slot | Lokasi | Posisi | `data` |
|---|---|---|---|
| `panel.navigation.before` | navigasi admin | sebelum | tidak ada |
| `panel.navigation.after` | navigasi admin | sesudah | tidak ada |
| `panel.overview.before` | ikhtisar admin | sebelum | tidak ada |
| `panel.overview.after` | ikhtisar admin | sesudah | tidak ada |
| `panel.users.before` | daftar pengguna | sebelum | `RouteSlotData` |
| `panel.users.after` | daftar pengguna | sesudah | `RouteSlotData` |
| `panel.users.create.before` | buat pengguna | sebelum | `RouteSlotData` |
| `panel.users.create.after` | buat pengguna | sesudah | `RouteSlotData` |
| `panel.users.detail.before` | detail pengguna | sebelum | `RouteSlotData` |
| `panel.users.detail.after` | detail pengguna | sesudah | `RouteSlotData` |
| `panel.users.detail.actions` | header detail pengguna | aksi | konteks `admin.user` |
| `panel.users.detail.form` | form pengguna asli | di dalam | `AdminUserFormSlotData` |
| `panel.locations.before` | daftar lokasi | sebelum | `RouteSlotData` |
| `panel.locations.after` | daftar lokasi | sesudah | `RouteSlotData` |
| `panel.locations.detail.before` | detail lokasi | sebelum | `RouteSlotData` |
| `panel.locations.detail.after` | detail lokasi | sesudah | `RouteSlotData` |
| `panel.nodes.before` | daftar node | sebelum | `RouteSlotData` |
| `panel.nodes.after` | daftar node | sesudah | `RouteSlotData` |
| `panel.nodes.create.before` | buat node | sebelum | `RouteSlotData` |
| `panel.nodes.create.after` | buat node | sesudah | `RouteSlotData` |
| `panel.nodes.detail.before` | detail node | sebelum | `RouteSlotData` |
| `panel.nodes.detail.after` | detail node | sesudah | `RouteSlotData` |
| `panel.nodes.detail.actions` | header detail node | aksi | konteks `admin.node` |
| `panel.nodes.detail.about.before` | tab About node | sebelum | `RouteSlotData` |
| `panel.nodes.detail.about.after` | tab About node | sesudah | `RouteSlotData` |
| `panel.nodes.detail.settings.before` | tab Settings node | sebelum | `RouteSlotData` |
| `panel.nodes.detail.settings.after` | tab Settings node | sesudah | `RouteSlotData` |
| `panel.nodes.detail.configuration.before` | tab Configuration node | sebelum | `RouteSlotData` |
| `panel.nodes.detail.configuration.after` | tab Configuration node | sesudah | `RouteSlotData` |
| `panel.nodes.detail.allocations.before` | tab Allocations node | sebelum | `RouteSlotData` |
| `panel.nodes.detail.allocations.after` | tab Allocations node | sesudah | `RouteSlotData` |
| `panel.nodes.detail.servers.before` | tab Servers node | sebelum | `RouteSlotData` |
| `panel.nodes.detail.servers.after` | tab Servers node | sesudah | `RouteSlotData` |
| `panel.servers.before` | daftar server | sebelum | `RouteSlotData` |
| `panel.servers.after` | daftar server | sesudah | `RouteSlotData` |
| `panel.servers.create.before` | buat server | sebelum | `RouteSlotData` |
| `panel.servers.create.after` | buat server | sesudah | `RouteSlotData` |
| `panel.servers.detail.before` | detail server | sebelum | `RouteSlotData` |
| `panel.servers.detail.after` | detail server | sesudah | `RouteSlotData` |
| `panel.servers.detail.actions` | header detail server | aksi | konteks `admin.server` |
| `panel.servers.detail.about.before` | tab About server | sebelum | `RouteSlotData` |
| `panel.servers.detail.about.after` | tab About server | sesudah | `RouteSlotData` |
| `panel.servers.detail.details.before` | tab Details server | sebelum | `RouteSlotData` |
| `panel.servers.detail.details.after` | tab Details server | sesudah | `RouteSlotData` |
| `panel.servers.detail.build.before` | tab Build server | sebelum | `RouteSlotData` |
| `panel.servers.detail.build.after` | tab Build server | sesudah | `RouteSlotData` |
| `panel.servers.detail.startup.before` | tab Startup server | sebelum | `RouteSlotData` |
| `panel.servers.detail.startup.after` | tab Startup server | sesudah | `RouteSlotData` |
| `panel.servers.detail.databases.before` | tab Databases server | sebelum | `RouteSlotData` |
| `panel.servers.detail.databases.after` | tab Databases server | sesudah | `RouteSlotData` |
| `panel.servers.detail.mounts.before` | tab Mounts server | sebelum | `RouteSlotData` |
| `panel.servers.detail.mounts.after` | tab Mounts server | sesudah | `RouteSlotData` |
| `panel.servers.detail.manage.before` | tab Manage server | sebelum | `RouteSlotData` |
| `panel.servers.detail.manage.after` | tab Manage server | sesudah | `RouteSlotData` |
| `panel.servers.detail.delete.before` | tab Delete server | sebelum | `RouteSlotData` |
| `panel.servers.detail.delete.after` | tab Delete server | sesudah | `RouteSlotData` |
| `panel.databaseHosts.before` | daftar host database | sebelum | `RouteSlotData` |
| `panel.databaseHosts.after` | daftar host database | sesudah | `RouteSlotData` |
| `panel.databaseHosts.create.before` | buat host database | sebelum | `RouteSlotData` |
| `panel.databaseHosts.create.after` | buat host database | sesudah | `RouteSlotData` |
| `panel.databaseHosts.detail.before` | detail host database | sebelum | `RouteSlotData` |
| `panel.databaseHosts.detail.after` | detail host database | sesudah | `RouteSlotData` |
| `panel.mounts.before` | daftar mount | sebelum | `RouteSlotData` |
| `panel.mounts.after` | daftar mount | sesudah | `RouteSlotData` |
| `panel.mounts.create.before` | buat mount | sebelum | `RouteSlotData` |
| `panel.mounts.create.after` | buat mount | sesudah | `RouteSlotData` |
| `panel.mounts.detail.before` | detail mount | sebelum | `RouteSlotData` |
| `panel.mounts.detail.after` | detail mount | sesudah | `RouteSlotData` |
| `panel.eggs.before` | daftar egg | sebelum | `RouteSlotData` |
| `panel.eggs.after` | daftar egg | sesudah | `RouteSlotData` |
| `panel.eggs.create.before` | buat egg | sebelum | `RouteSlotData` |
| `panel.eggs.create.after` | buat egg | sesudah | `RouteSlotData` |
| `panel.eggs.detail.before` | detail egg | sebelum | `RouteSlotData` |
| `panel.eggs.detail.after` | detail egg | sesudah | `RouteSlotData` |
| `panel.eggs.detail.actions` | header detail egg | aksi | konteks `admin.egg` |
| `panel.eggs.detail.configuration.before` | tab Configuration egg | sebelum | `RouteSlotData` |
| `panel.eggs.detail.configuration.after` | tab Configuration egg | sesudah | `RouteSlotData` |
| `panel.eggs.detail.tags.before` | tab Tags egg | sebelum | `RouteSlotData` |
| `panel.eggs.detail.tags.after` | tab Tags egg | sesudah | `RouteSlotData` |
| `panel.eggs.detail.variables.before` | tab Variables egg | sebelum | `RouteSlotData` |
| `panel.eggs.detail.variables.after` | tab Variables egg | sesudah | `RouteSlotData` |
| `panel.eggs.detail.script.before` | tab Install script egg | sebelum | `RouteSlotData` |
| `panel.eggs.detail.script.after` | tab Install script egg | sesudah | `RouteSlotData` |
| `panel.tags.before` | halaman tag | sebelum | `RouteSlotData` |
| `panel.tags.after` | halaman tag | sesudah | `RouteSlotData` |
| `panel.activity.before` | halaman aktivitas admin | sebelum | `RouteSlotData` |
| `panel.activity.after` | halaman aktivitas admin | sesudah | `RouteSlotData` |
| `panel.settings.before` | halaman pengaturan | sebelum | `RouteSlotData` |
| `panel.settings.after` | halaman pengaturan | sesudah | `RouteSlotData` |
| `panel.extensions.before` | halaman Extensions | sebelum | `RouteSlotData` |
| `panel.extensions.after` | halaman Extensions | sesudah | `RouteSlotData` |
| `panel.apiKeys.before` | halaman kunci API | sebelum | `RouteSlotData` |
| `panel.apiKeys.after` | halaman kunci API | sesudah | `RouteSlotData` |

Daftar slot ini disalin dari dokumen upstream (`reference.mdx`, bagian "Slots"). Saya belum memeriksanya satu per satu terhadap daftar di kode tag beta.2. Itu pekerjaan lanjutan yang masih terbuka.

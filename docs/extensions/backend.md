# Backend extension: provider, rute, otorisasi, migrasi, pengaturan, field form

> **Jenis:** Panduan + referensi · **Per:** 2026-10-20 · **Sumber utama:** [Backend](https://docs.pterodactyl.io/v2/extensions/backend) (`backend.mdx`) · **Diperiksa di kode:** `ExtensionProvider.php`, `ExtensionCompatibility.php`, `ExtensionSettingDefinition.php`, `ExtensionManifestValidator.php` pada tag `v2.0.0-beta.2` · **Kembali ke:** [indeks extension](README.md)

Backend extension berjalan di dalam Panel seperti paket Laravel. Halaman ini melanjutkan contoh Server Notes dari [membangun extension](membangun.md). Semua bagian yang bertanda **(kode)** berasal dari sumber Panel beta.2, bukan dari dokumen upstream.

## Service provider

Backend dimulai dari service provider yang harus memperluas `Pterodactyl\Extensions\ExtensionProvider`:

```php
<?php

namespace ServerNotes;

use Pterodactyl\Extensions\ExtensionProvider;

class ServerNotesProvider extends ExtensionProvider
{
    public function boot(): void
    {
        $this->registerApiRoutes();
        $this->loadExtensionMigrations();
    }
}
```

- `register` untuk binding container, `boot` untuk sisanya.
- Panel memuat provider pada setiap request. Bila provider melempar exception, Panel melewati extension, menampilkan error di area admin, dan tetap berjalan.

Metode yang tersedia dari base class (tag beta.2):

| Metode | Fungsi |
|---|---|
| `registerApiRoutes()` | memuat `routes/client.php`, `server.php`, `admin.php`, dan `application.php` bila ada |
| `loadExtensionMigrations()` | mendaftarkan `database/migrations` |
| `registerSettings($definition)` | mendaftarkan pengaturan |
| `settings()` | penyimpanan nilai key-value extension |
| `registerPermissions($description, $keys)` | mendaftarkan izin di bawah `ext.{id}.{key}` |
| `registerFields($model, $fields)` | menambah field ke form admin model |
| `listenToServerOperations($listener)` | mendengarkan hasil operasi server |
| `loadExtensionViews()` / `loadExtensionTranslations()` | view dan terjemahan dengan namespace `ext-{id}` |
| `registerRootRoutes()`, `registerWebRoutes()`, `registerAuthenticatedWebRoutes()`, `registerHeadTags()` | rute web dan tag kepala (dibahas di [referensi](referensi.md#metode-provider)) |
| `id()`, `extensionPath(...$parts)` | ID extension dan path absolut di dalam direktorinya |

## Rute

Rute ditaruh di direktori `routes`. `registerApiRoutes` memuat setiap berkas yang ada, masing-masing dengan prefiks URL dan middleware sendiri.

| Berkas | Prefiks URL | Siapa yang boleh memanggil |
|---|---|---|
| `routes/client.php` | `/api/client/extensions/{id}` | pengguna yang sudah masuk, atau kunci Client API |
| `routes/server.php` | `/api/client/servers/{server}/extensions/{id}` | pengguna yang punya akses ke server |
| `routes/admin.php` | `/api/admin/extensions/{id}` | administrator root |
| `routes/application.php` | `/api/application/extensions/{id}` | administrator root, termasuk kunci Application API |

Rute ini memakai middleware autentikasi, dua faktor, dan batas laju yang sama dengan API Panel, jadi extension tidak perlu menangani proses masuk sendiri.

Contoh rute server Server Notes:

```php
<?php

use Illuminate\Support\Facades\Route;
use ServerNotes\Http\Controllers\NoteController;

// GET|PUT /api/client/servers/{server}/extensions/server-notes/note
Route::get('/note', [NoteController::class, 'show']);
Route::put('/note', [NoteController::class, 'update']);
```

Pada rute server, `{server}` sudah diselesaikan. Tulis type hint `Pterodactyl\Models\Server` di controller:

```php
public function show(Server $server): JsonResponse
{
    $note = Note::query()->where('server_id', $server->id)->first();

    return new JsonResponse([
        'body' => $note->body ?? '',
        'updated_at' => $note?->updated_at?->toAtomString(),
    ]);
}
```

Untuk rute web (bukan API), panggil `registerWebRoutes` atau `registerAuthenticatedWebRoutes` dengan path berkas rute. Rute web dilayani di `/extensions/{id}`.

## Otorisasi

Panel memeriksa bahwa pengguna boleh mengakses server sebelum rute server dijalankan. Pengguna tanpa akses menerima `404`.

Untuk memeriksa izin tertentu, panggil `can` dengan salah satu izin subuser. Pemilik server dan administrator root lolos semua pemeriksaan. Contoh: setiap pengguna boleh membaca catatan, tetapi hanya yang boleh mengedit file boleh mengubahnya.

```php
public function update(Request $request, Server $server): JsonResponse
{
    abort_unless($request->user()->can('file.update', $server), 403, 'You do not have permission to edit notes.');

    // ...
}
```

Izin sendiri didaftarkan di `boot`:

```php
$this->registerPermissions('Manage server notes.', [
    'read' => 'Read server notes.',
    'update' => 'Change server notes.',
]);
```

Kunci itu menjadi `ext.server-notes.read` dan `ext.server-notes.update`, dan muncul di editor izin subuser. Wildcard `ext.server-notes.*` hanya mencakup izin extension itu.

Daftar izin inti (dari dokumen referensi): Console, Subusers, Files, Backups, Network, Startup, Databases, Schedules, Settings, dan Activity. Nama lengkapnya ada di [referensi](referensi.md#izin).

## Migrasi basis data

Taruh migrasi di `database/migrations` dan panggil `loadExtensionMigrations` di `boot`. Panel menjalankannya saat administrator mengaktifkan extension, sebelum menandainya aktif.

Awali nama tabel dengan `ext_` dan ID extension (tanda hubung diganti garis bawah) agar tidak bertabrakan dengan tabel Panel:

```php
Schema::create('ext_server_notes_notes', function (Blueprint $table) {
    $table->id();
    $table->unsignedInteger('server_id')->unique();
    $table->text('body');
    $table->timestamps();

    $table->foreign('server_id')->references('id')->on('servers')->cascadeOnDelete();
});
```

- Menonaktifkan atau menghapus extension mempertahankan tabelnya. Pasang ulang, dan datanya kembali.
- Pemulihan paket tidak membatalkan perubahan skema. Rancang migrasi agar perubahan yang selesai sebagian bisa dikenali dan dipulihkan.
- **(kode)** Laravel mencatat migrasi berdasarkan nama berkasnya. Karena itu, nama migrasi extension **tidak boleh sama** dengan migrasi Panel atau migrasi extension lain yang terpasang. Bila sama, migrasi itu dianggap sudah jalan dan tidak pernah dieksekusi. Pemeriksaannya ada di `ExtensionCompatibility::assertMigrationsAreUnique`; pesan errornya menyuruh mengganti nama berkas. Titik pemanggilannya tidak saya telusuri lebih jauh, jadi anggap ini aturan yang ditegakkan sebelum migrasi berjalan, bukan pada saat tertentu.

Model Eloquent dipakai seperti biasa:

```php
<?php

namespace ServerNotes\Models;

use Illuminate\Database\Eloquent\Model;

class Note extends Model
{
    protected $table = 'ext_server_notes_notes';

    protected $fillable = ['server_id', 'body'];
}
```

## Pengaturan

Pengaturan didefinisikan di `boot` provider. Administrator mengubahnya di **Admin → Extensions**, pada form yang dibangun Panel:

```php
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

public function boot(): void
{
    // ...

    $this->registerSettings(new ExtensionSettingsDefinition($this->settings(), [
        ExtensionSettingDefinition::make('max_length', 'max_length', 2000, ['required', 'integer', 'min:100', 'max:20000'])
            ->label('Maximum note length')
            ->help('The longest note, in characters, that users can save.')
            ->field('number')
            ->frontend()
            ->frontendType('number'),
    ]));
}
```

`make` menerima kunci penyimpanan, nama field form, nilai bawaan, dan aturan validasi. Berikan aturan yang sesuai dengan nilai yang diterima.

### Tipe field

Dokumen upstream mendaftar lima tipe. Kode beta.2 (`ExtensionSettingDefinition::FIELDS`) mengenal **sepuluh**:

| Tipe | Di dokumen? | Catatan dari kode |
|---|---|---|
| `text` | ya | bawaan |
| `password` | ya | `password` otomatis mengaktifkan `secret()`, jadi nilainya terenkripsi |
| `number` | ya | |
| `toggle` | ya | nilai bawaan `true`, `false`, atau `null` |
| `select` | ya | butuh daftar opsi `['value' => ..., 'label' => ...]` |
| `color` | **tidak** | dengan metode `color()` |
| `textarea` | **tidak** | dengan metode `textarea()` |
| `multiselect` | **tidak** | dengan metode `multiselect()` |
| `list` | **tidak** | dengan metode `list()` |
| `file` | **tidak** | dengan metode `file(array $mimes, int $maxKilobytes = 1024)`; berkas diunggah administrator, diberi nama acak, dan disajikan lewat `/extension-files` dengan header sandbox |

Tipe `color`, `textarea`, `multiselect`, `list`, dan `file` tidak boleh dipakai bersama `secret()`. Tipe `file` juga tidak boleh diberi nilai bawaan selain URL atau `null`.

### Membaca pengaturan

Di kode backend, minta `ExtensionSettingsRegistry` lewat type hint dan ambil definisi extension darinya. Nilai yang belum pernah disimpan mengembalikan nilai bawaan:

```php
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

$maxLength = $registry->get('server-notes')->get('max_length');
```

Server Notes memakainya untuk memvalidasi catatan baru:

```php
public function update(Request $request, Server $server, ExtensionSettingsRegistry $settings): JsonResponse
{
    abort_unless($request->user()->can('file.update', $server), 403, 'You do not have permission to edit notes.');

    $data = $request->validate([
        'body' => ['present', 'nullable', 'string', 'max:'.$settings->get('server-notes')->get('max_length')],
    ]);

    $note = Note::query()->updateOrCreate(['server_id' => $server->id], ['body' => $data['body'] ?? '']);

    return new JsonResponse([
        'body' => $note->body,
        'updated_at' => $note->updated_at->toAtomString(),
    ]);
}
```

### Nilai frontend (`frontend()`)

- `frontend()` mengirim nilai ke bundel frontend sebagai `config`. **Setiap pengguna yang sudah masuk bisa membacanya.** Jangan pernah menandai rahasia sebagai nilai frontend.
- Halaman sebelum masuk (mis. halaman login) tetap memuat bundel, tetapi dengan `config` kosong.
- `frontendType` menyatakan tipe nilai publik: `string`, `number`, `boolean`, `array`, `object`, `null`, atau `json` (bawaan). Panel memeriksa tipe sebelum nilai diekspos (`ExtensionSettingDefinition::frontendType`).

### Penyimpanan global dan rahasia

`$this->settings()` menyimpan nilai untuk seluruh extension. Metodenya: `get`, `set`, `forget`, dan `all`. Untuk nilai yang dikelola extension sendiri dan tidak boleh diubah administrator, pakai penyimpanan ini langsung.

Untuk nilai per pengguna, server, node, egg, lokasi, mount, atau host database, gunakan `forUser`, `forServer`, atau `for($model)`. Menghapus model ikut menghapus nilai bercakupannya:

```php
$preferences = $this->settings()->forUser($user);
$preferences->set('show_preview', true);

$serverSettings = $this->settings()->forServer($server);
$serverSettings->set('summary_enabled', true);
$serverSettings->setSecret('webhook_token', $token);
```

- Baca rahasia dengan `get`. Gunakan `setSecret` setiap kali menggantinya agar tetap terenkripsi.
- Rahasia di form admin dibuat dengan `secret()` pada definisinya. Form menampilkannya sebagai password kosong, dan pembaruan kosong mempertahankan nilai tersimpan.

```php
ExtensionSettingDefinition::make('webhook_token', 'webhook_token', '', ['nullable', 'string', 'max:2000'])
    ->label('Webhook token')
    ->secret();
```

`field('password')` saja **tidak** mengenkripsi nilai. Perlu `secret()`.

## Field tambahan di form admin

Extension bisa menambah field pada form create dan edit admin untuk pengguna, server, node, egg, lokasi, mount, dan host database. Panel memvalidasi nilainya bersama form, menyimpannya dalam transaksi yang sama, dan mengembalikannya pada resource.

Deklarasikan field di kelas yang memperluas `Pterodactyl\Extensions\Fields`, lalu daftarkan di provider dengan `registerFields`, sekali untuk setiap model:

```php
<?php

namespace ServerNotes;

use Pterodactyl\Extensions\Fields;
use Pterodactyl\Models\Server;
use ServerNotes\Models\Note;

final class ServerNoteFields extends Fields
{
    public function rules(): array
    {
        return ['body' => ['nullable', 'string', 'max:2000']];
    }

    public function values(Server $server): array
    {
        return ['body' => Note::query()->where('server_id', $server->id)->value('body') ?? ''];
    }

    public function save(Server $server, array $values): void
    {
        Note::query()->updateOrCreate(['server_id' => $server->id], ['body' => $values['body'] ?? '']);
    }
}
```

```php
use Pterodactyl\Models\Server;

public function boot(): void
{
    // ...

    $this->registerFields(Server::class, ServerNoteFields::class);
}
```

Semua metode bersifat opsional. Panel memanggilnya lewat service container, jadi setiap metode boleh men-type-hint model dan dependensi lain.

| Metode | Dipanggil | Fungsi |
|---|---|---|
| `rules()` | setiap penyimpanan yang memvalidasi extension ini, termasuk pembuatan | aturan validasi per field; hanya berlaku untuk nilai extension ini (mis. `required_if:mode,custom` merujuk field `mode` milik extension) |
| `values($model)` | saat resource dikembalikan | nilai saat ini, per field |
| `save($model, $values)` | di dalam transaksi penulisan model, setelah barisnya ditulis | menyimpan nilai tervalidasi. Nama parameter kedua **harus** `$values` |
| `authorize()` | sebelum nilai diterima atau dikembalikan | apakah administrator yang sedang masuk boleh melihat dan mengubah nilai |
| `secrets()` | saat nilai disimpan dan dikembalikan | nama field yang berisi kredensial; dienkripsi dan dikembalikan sebagai `********` |
| `attributes()`, `messages()` | saat validasi | nama field dan pesan error |

**(kode)** Metode selain `values` dan `save` juga dipanggil saat model dibuat. Maka parameter model di `rules`, `authorize`, `secrets`, `attributes`, atau `messages` harus nullable, mis. `?Server $server`. Nilainya `null` saat pembuatan.

**(kode)** Pendaftaran akan menghentikan extension bila: model tidak didukung; kelas tidak memperluas `Fields`; hanya salah satu dari `values` atau `save` yang diimplementasikan; atau model yang sama didaftarkan dua kali.

**Bila `values` dan `save` keduanya tidak ada**, Panel menyimpan nilai untuk Anda. Baca nilainya dengan `$this->settings()->fields($model)`. Nilai itu terpisah dari pengaturan bercakupan lain, sehingga `for`, `forUser`, dan `forServer` tidak pernah mengembalikannya.

### Validasi

- **Pembuatan model:** aturan setiap extension yang boleh diubah administrator dijalankan, baik request menyertakan nilainya maupun tidak. Field `required` selalu berlaku.
- **Pembaruan model:** aturan dijalankan hanya untuk extension yang disertakan request, meskipun tanpa nilai. Extension yang tidak disertakan tidak menjalankan aturan atau `save`-nya, dan nilai tersimpannya tetap.
- Form admin Panel selalu mengirim setiap extension yang ditampilkannya, sehingga `required` berlaku seperti pada field Panel sendiri.
- Error validasi dilaporkan sebagai `extensions.{id}.{field}`.

### Penyimpanan

`save` berjalan dalam transaksi yang menulis model, setelah barisnya tertulis dan sebelum Wings dihubungi. Bila `save` melempar exception, seluruh perubahan dibatalkan. Pekerjaan yang harus menunggu commit, seperti memanggil layanan luar, taruh di `DB::afterCommit()`.

Saat extension nonaktif atau gagal dimuat, nilai yang dikirim untuknya diabaikan dan nilai tersimpannya dibiarkan.

### Otorisasi dan rahasia

Hanya administrator root yang mencapai endpoint admin, dan `$user->can()` meloloskan semuanya untuk administrator root. Untuk membatasi siapa yang boleh mengubah field, putuskan di `authorize`, mis. berdasarkan ID administrator atau peran yang disimpan extension. Gunakan `#[CurrentUser] User $admin` untuk mendapat administrator yang sedang masuk. Permintaan yang ditolak `authorize` menerima `403`, dan nilainya dikeluarkan dari respons.

Field yang tercantum di `secrets` dienkripsi saat disimpan dan dikembalikan sebagai `********`. Pengiriman topeng itu atau field yang dihilangkan mempertahankan nilai. Mengirim `null` atau string kosong menghapusnya.

### API

Endpoint create dan update admin untuk setiap resource menerima objek `extensions`, dengan kunci ID extension lalu nama field:

```json
{
    "name": "Survival",
    "extensions": {
        "server-notes": { "body": "Restart nightly at 04:00." }
    }
}
```

Respons untuk satu resource menyertakan nilai sebagai `attributes.extensions`. Daftar tidak menyertakannya. Bila `values` melempar exception, kegagalan dicatat di **Admin → Extensions**.

Untuk juga menerima dan mengembalikan nilai di Application API, tambahkan atribut `#[ApplicationApi]` (`Pterodactyl\Extensions\Attributes\ApplicationApi`) ke kelas. Ini berlaku untuk endpoint user, node, lokasi, dan server di Application API. Aturan `required` ikut berlaku di sana: membuat resource lewat Application API gagal sampai request menyertakan field itu.

Untuk menggambar field di form admin, lihat [penggantian form asli](frontend.md#form-asli).

## Event operasi server

Untuk bereaksi terhadap operasi server yang selesai, daftarkan listener dengan `listenToServerOperations` di provider. Listener menerima `Pterodactyl\Events\Server\OperationCompleted`:

| Properti | Nilai |
|---|---|
| `serverUuid` | UUID server |
| `operation` | `provision`, `install`, `reinstall`, atau `backup` |
| `successful` | apakah operasi berhasil |
| `resourceUuid` | UUID backup untuk backup; UUID server untuk operasi lain |

Properti bersifat hanya-baca. Event dikirim setelah commit basis data. Provisioning dilaporkan setelah Wings menerima pembuatan server. Bila listener melempar exception, kegagalannya dicatat untuk extension tersebut.

## Progres pekerjaan panjang

Untuk pekerjaan yang lama, inject `Pterodactyl\Services\Extensions\ExtensionJobProgress` ke controller atau job. Buat snapshot untuk pengguna yang memulai pekerjaan:

```php
$job = $progress->begin('server-notes', $user, $server, 'ext.server-notes.update');
```

Kembalikan `$job->id` ke frontend dan berikan ke worker yang memperbaruinya:

```php
$progress->update('server-notes', $jobId, 40, 'Reading server notes.');
$progress->update('server-notes', $jobId, 100, 'Summary ready.', 'completed');
```

- Progres hanya maju, dari 0 ke 100. Status: `running`, `completed`, atau `failed`. Snapshot yang sudah selesai tidak bisa diubah.
- Tanpa server dan izin, job hanya milik pengguna. Job pengguna dan job server tanpa izin terlihat hanya untuk pembuatnya dan administrator root. Job server dengan izin terlihat untuk pengguna yang masih punya izin itu dan akses ke server.
- Web request dan worker harus memakai cache store yang sama.
- Snapshot kedaluwarsa menurut `extensions.progress_retention_seconds` (bawaan 3600 detik sejak pembaruan terakhir). Simpan hasil dan riwayat audit di tempat lain.
- Endpoint baca: `/api/client/extension-progress/{extension}/{job}` untuk job pengguna, dan `/api/client/servers/{server}/extension-progress/{extension}/{job}` untuk job server.

Frontend memakai hook `useExtensionJobProgress`; lihat [data dan gaya](data-dan-gaya.md#panggilan-ke-api-anda).

## Views dan terjemahan

Untuk view Blade, taruh di `resources/views` dan panggil `loadExtensionViews`. Untuk terjemahan, taruh di `resources/lang` dan panggil `loadExtensionTranslations`. Keduanya memakai namespace `ext-{id}`, mis. `ext-server-notes::notes.title`.

## Kode, autoload, dan rute akar (kode)

Aturan berikut tidak ada di dokumen upstream, tetapi diterapkan oleh kode beta.2:

- **Namespace PSR-4** extension tidak boleh tumpang tindih dengan namespace Panel (`Pterodactyl\`, `Illuminate\`, `Laravel\`, `Symfony\`, dan prefiks dari autoloader Panel) atau dengan extension lain yang aktif. Pelanggaran membuat pemasangan ditolak.
- **Autoloader Composer** di `vendor/autoload.php` extension memakai akhiran kelas `ComposerAutoloaderInit{suffix}`. Bila sama dengan Panel atau extension aktif lain, PHP berhenti di deklarasi kedua dan **seluruh request gagal**. Solusinya: set `config.autoloader-suffix` di `composer.json` lalu jalankan `composer dump-autoload`.
- **Prefiks rute akar** (`routes.root`) tidak boleh menimpa rute inti, segmen rute yang sudah terdaftar, atau berkas di direktori publik. Dua extension aktif tidak boleh mengklaim prefiks yang sama.
- **Dependensi** harus aktif sebelum dependen. Siklus ditolak.

Sumber: `ExtensionCompatibility.php` (`assertDistinctAutoloader`, `assertMigrationsAreUnique`, `failureReason`) dan `ExtensionManifestValidator.php` (`assertRootPrefixesAreFree`, `normalizeAutoload`).

## Lihat juga

- [Membangun extension](membangun.md)
- [Frontend](frontend.md)
- [Referensi](referensi.md#metode-provider) untuk daftar lengkap metode, rute, dan event.

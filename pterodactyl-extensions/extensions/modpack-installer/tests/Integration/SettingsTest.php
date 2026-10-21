<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Validator;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Tests\ExtensionTestCase;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

uses(ExtensionTestCase::class);

// NFR-MI2, AC-MI20: the CurseForge key is a secret, and the settings have the ranges the spec gives.

it('never sends the API key back in the settings response, only a mask', function (): void {
    $admin = Pterodactyl\Models\User::factory()->create(['root_admin' => true]);
    $this->configureCurseForge();

    $response = $this->actingAs($admin)->getJson('/api/admin/extensions/modpack-installer/settings')->assertOk();

    expect($response->getContent())->toContain('********')
        ->and($response->getContent())->not->toContain(ExtensionTestCase::API_KEY);
});

it('reads the key back through the settings class', function (): void {
    $this->configureCurseForge();

    expect($this->settings()->curseforgeApiKey())->toBe(ExtensionTestCase::API_KEY);
});

it('has no key until one is set, and an empty one is no key', function (): void {
    expect($this->settings()->curseforgeApiKey())->toBeNull();

    $this->configure(['curseforge_api_key' => '']);

    expect($this->settings()->curseforgeApiKey())->toBeNull();
});

it('has the documented defaults', function (): void {
    expect($this->settings()->maxDownloadMb())->toBe(512)
        ->and($this->settings()->searchCacheSeconds())->toBe(60)
        ->and($this->settings()->extraSanitizedFiles())->toBe([]);
});

it('reads what the admin saved', function (): void {
    $this->configure(['max_download_mb' => 2048, 'search_cache_seconds' => 120, 'extra_sanitized_files' => ['custom.sh', 'extra.bat']]);

    expect($this->settings()->maxDownloadMb())->toBe(2048)
        ->and($this->settings()->searchCacheSeconds())->toBe(120)
        ->and($this->settings()->extraSanitizedFiles())->toBe(['custom.sh', 'extra.bat']);
});

it('is validated to the ranges of the spec', function (string $key, mixed $value, bool $valid): void {
    $rules = $this->app->make(ExtensionSettingsRegistry::class)->get('modpack-installer')->validationRules();

    expect(Validator::make([$key => $value], [$key => $rules[$key]])->passes())->toBe($valid);
})->with([
    'download 10' => ['max_download_mb', 10, true],
    'download 4096' => ['max_download_mb', 4096, true],
    'download 9' => ['max_download_mb', 9, false],
    'download 4097' => ['max_download_mb', 4097, false],
    'cache 0' => ['search_cache_seconds', 0, true],
    'cache 300' => ['search_cache_seconds', 300, true],
    'cache 301' => ['search_cache_seconds', 301, false],
    'cache -1' => ['search_cache_seconds', -1, false],
    'key 256' => ['curseforge_api_key', str_repeat('k', 256), true],
    'key 257' => ['curseforge_api_key', str_repeat('k', 257), false],
]);

it('refuses an extra file that is a path, and a list longer than twenty (EC-MI11)', function (): void {
    $rules = $this->app->make(ExtensionSettingsRegistry::class)->get('modpack-installer')->validationRules();
    $passes = fn (array $list): bool => Validator::make(['extra_sanitized_files' => $list], ['extra_sanitized_files' => $rules['extra_sanitized_files'], 'extra_sanitized_files.*' => $rules['extra_sanitized_files.*'] ?? 'string'])->passes();

    expect($passes(['custom.sh']))->toBeTrue()
        ->and($passes(['config/server.properties']))->toBeFalse()
        ->and($passes(array_map(fn (int $i): string => "f{$i}.sh", range(1, 21))))->toBeFalse();
});

it('keeps the API addresses out of the settings, so nobody can point the Panel at an internal host (NFR-MI3)', function (): void {
    $keys = array_keys($this->app->make(ExtensionSettingsRegistry::class)->get('modpack-installer')->validationRules());

    expect(array_filter($keys, fn (string $key): bool => str_contains($key, 'url') || str_contains($key, 'endpoint') || str_contains($key, 'host')))->toBe([]);
});

it('creates the installs table with the columns the code uses, and no unique key that would stop a second install', function (): void {
    $columns = Schema::getColumnListing('ext_modpack_installer_jobs');

    expect($columns)->toContain('id', 'server_uuid', 'source', 'project_id', 'file_id', 'target_directory', 'job_id', 'status', 'last_error', 'created_at', 'updated_at');

    $unique = collect(Schema::getIndexes('ext_modpack_installer_jobs'))->filter(fn (array $index): bool => $index['unique'] && ! $index['primary']);

    expect($unique)->toHaveCount(0);
});

it('can be read through the container', function (): void {
    expect($this->app->make(ModpackSettings::class))->toBeInstanceOf(ModpackSettings::class);
});

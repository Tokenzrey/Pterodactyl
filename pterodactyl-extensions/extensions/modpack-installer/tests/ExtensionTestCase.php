<?php

declare(strict_types=1);

namespace ModpackInstaller\Tests;

use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Http;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\TmpStore;
use ModpackInstaller\Support\WingsFileService;
use Pterodactyl\Models\Extension;
use Pterodactyl\Services\Extensions\ExtensionProviderLoader;
use Pterodactyl\Services\Extensions\ExtensionRepository;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use Pterodactyl\Tests\Integration\IntegrationTestCase;
use RuntimeException;

/**
 * Boots the Panel with modpack-installer installed and enabled from its source directory, the way the loader would.
 * Nothing leaves the test: Wings is a recording fake, the temporary store is a temporary directory, and any HTTP call
 * that a test did not fake is an error (NFR-MI8).
 */
abstract class ExtensionTestCase extends IntegrationTestCase
{
    use DatabaseTransactions;

    public const API_KEY = 'cf-test-key-DO-NOT-LEAK-0123456789';

    public FakeWingsFileService $wings;

    /** Public so that a test helper outside the class can look inside it. */
    public string $tmpRoot;

    private string $assets;

    protected function setUp(): void
    {
        parent::setUp();

        $this->assets = sys_get_temp_dir().'/modpack-installer-assets-'.uniqid();
        config([
            'extensions.enabled' => true,
            'extensions.directory' => '/ext-src',
            'extensions.assets_directory' => $this->assets,
        ]);
        $this->app->forgetInstance(ExtensionRepository::class);
        $this->app->forgetInstance(ExtensionProviderLoader::class);

        Extension::query()->create(['identifier' => 'modpack-installer', 'version' => '1.0.0', 'enabled' => true]);
        $repository = $this->app->make(ExtensionRepository::class);
        $repository->flushDiscovery();
        $this->app->make(ExtensionProviderLoader::class)->registerProviders($repository->enabled());

        // The Panel records a failed boot on the extension row and carries on; a test must not.
        $error = Extension::query()->where('identifier', 'modpack-installer')->value('error');
        if ($error !== null) {
            throw new RuntimeException("modpack-installer failed to load: $error");
        }

        $this->tmpRoot = sys_get_temp_dir().'/modpack-installer-store-'.uniqid();
        $this->app->instance(TmpStore::class, new TmpStore($this->tmpRoot));

        $this->wings = new FakeWingsFileService();
        $this->app->instance(WingsFileService::class, $this->wings);

        Http::preventStrayRequests();

        // Searches are cached, and a cache that survives from one test to the next would answer for the wrong one.
        Cache::flush();
    }

    protected function tearDown(): void
    {
        $this->app->make(ExtensionRepository::class)->flushDiscovery();
        File::deleteDirectory($this->assets);
        File::deleteDirectory($this->tmpRoot);

        parent::tearDown();
    }

    /** Saves the extension's global settings, as the admin form does. @param array<string, mixed> $values */
    protected function configure(array $values): void
    {
        $this->app->make(ExtensionSettingsRegistry::class)->get('modpack-installer')->update($values);
    }

    /** A working setup: a CurseForge key and the documented defaults. @param array<string, mixed> $more */
    protected function configureCurseForge(array $more = []): void
    {
        $this->configure(['curseforge_api_key' => self::API_KEY, ...$more]);
    }

    protected function settings(): ModpackSettings
    {
        return ModpackSettings::fromRegistry($this->app->make(ExtensionSettingsRegistry::class));
    }
}

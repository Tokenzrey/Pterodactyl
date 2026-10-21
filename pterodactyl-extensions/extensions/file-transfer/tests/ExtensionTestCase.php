<?php

declare(strict_types=1);

namespace FileTransfer\Tests;

use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\WingsFileService;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Http;
use Pterodactyl\Models\Extension;
use Pterodactyl\Services\Extensions\ExtensionProviderLoader;
use Pterodactyl\Services\Extensions\ExtensionRepository;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use Pterodactyl\Tests\Integration\IntegrationTestCase;
use RuntimeException;

/**
 * Boots the Panel with file-transfer installed and enabled from its source directory, the way the loader would.
 * Nothing leaves the test: Wings is a recording fake, the chunk store is a temporary directory, and any HTTP call
 * that a test did not fake is an error (NFR-FT9).
 */
abstract class ExtensionTestCase extends IntegrationTestCase
{
    use DatabaseTransactions;

    protected FakeWingsFileService $wings;

    /** Public so that a test helper outside the class can age files in it. */
    public string $storeRoot;

    private string $assets;

    protected function setUp(): void
    {
        parent::setUp();

        $this->assets = sys_get_temp_dir().'/file-transfer-assets-'.uniqid();
        config([
            'extensions.enabled' => true,
            'extensions.directory' => '/ext-src',
            'extensions.assets_directory' => $this->assets,
        ]);
        $this->app->forgetInstance(ExtensionRepository::class);
        $this->app->forgetInstance(ExtensionProviderLoader::class);

        Extension::query()->create(['identifier' => 'file-transfer', 'version' => '1.0.0', 'enabled' => true]);
        $repository = $this->app->make(ExtensionRepository::class);
        $repository->flushDiscovery();
        $this->app->make(ExtensionProviderLoader::class)->registerProviders($repository->enabled());

        // The Panel records a failed boot on the extension row and carries on; a test must not.
        $error = Extension::query()->where('identifier', 'file-transfer')->value('error');
        if ($error !== null) {
            throw new RuntimeException("file-transfer failed to load: $error");
        }

        $this->storeRoot = sys_get_temp_dir().'/file-transfer-store-'.uniqid();
        $this->app->instance(ChunkStore::class, new ChunkStore($this->storeRoot));

        $this->wings = new FakeWingsFileService();
        $this->app->instance(WingsFileService::class, $this->wings);

        Http::preventStrayRequests();
    }

    protected function tearDown(): void
    {
        $this->app->make(ExtensionRepository::class)->flushDiscovery();
        File::deleteDirectory($this->assets);
        File::deleteDirectory($this->storeRoot);

        parent::tearDown();
    }

    /** Saves the extension's global settings, as the admin form does. @param array<string, mixed> $values */
    protected function configure(array $values): void
    {
        $this->app->make(ExtensionSettingsRegistry::class)->get('file-transfer')->update($values);
    }
}

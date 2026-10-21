<?php

declare(strict_types=1);

namespace PlayerManager\Tests;

use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\File;
use Pterodactyl\Contracts\Servers\ReadsServerState;
use Pterodactyl\Models\Extension;
use Pterodactyl\Services\Extensions\ExtensionProviderLoader;
use Pterodactyl\Services\Extensions\ExtensionRepository;
use Pterodactyl\Tests\Integration\IntegrationTestCase;
use RuntimeException;

/**
 * Boots the Panel with the player-manager extension installed and enabled from its source directory, the way the
 * loader would, so the provider, routes, permissions and settings are the real ones.
 */
abstract class ExtensionTestCase extends IntegrationTestCase
{
    use DatabaseTransactions;

    private string $assets;

    protected FakeServerState $wings;

    protected function setUp(): void
    {
        parent::setUp();

        $this->assets = sys_get_temp_dir().'/player-manager-assets-'.uniqid();
        config([
            'extensions.enabled' => true,
            'extensions.directory' => '/ext-src',
            'extensions.assets_directory' => $this->assets,
        ]);
        $this->app->forgetInstance(ExtensionRepository::class);
        $this->app->forgetInstance(ExtensionProviderLoader::class);

        // Wings is never called in tests. A running server is the default; a test changes $this->wings->result.
        $this->wings = new FakeServerState();
        $this->app->instance(ReadsServerState::class, $this->wings);

        Extension::query()->create(['identifier' => 'player-manager', 'version' => '1.0.0', 'enabled' => true]);
        $repository = $this->app->make(ExtensionRepository::class);
        $repository->flushDiscovery();
        $this->app->make(ExtensionProviderLoader::class)->registerProviders($repository->enabled());

        // The Panel records a failed boot on the extension row and carries on; a test must not.
        $error = Extension::query()->where('identifier', 'player-manager')->value('error');
        if ($error !== null) {
            throw new RuntimeException("player-manager failed to load: $error");
        }
    }

    protected function tearDown(): void
    {
        $this->app->make(ExtensionRepository::class)->flushDiscovery();
        File::deleteDirectory($this->assets);

        parent::tearDown();
    }
}

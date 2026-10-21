<?php

declare(strict_types=1);

namespace MultiNodeSync\Tests;

use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\File;
use MultiNodeSync\Support\MultiNodeSyncSettings;
use Pterodactyl\Models\Extension;
use Pterodactyl\Models\Location;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionProviderLoader;
use Pterodactyl\Services\Extensions\ExtensionRepository;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use Pterodactyl\Tests\Integration\IntegrationTestCase;
use RuntimeException;

abstract class ExtensionTestCase extends IntegrationTestCase
{
    use DatabaseTransactions;

    private string $assets;

    protected function setUp(): void
    {
        parent::setUp();

        $this->assets = sys_get_temp_dir().'/multi-node-sync-assets-'.uniqid();
        config([
            'extensions.enabled' => true,
            'extensions.directory' => '/ext-src',
            'extensions.assets_directory' => $this->assets,
        ]);
        $this->app->forgetInstance(ExtensionRepository::class);
        $this->app->forgetInstance(ExtensionProviderLoader::class);

        Extension::query()->create(['identifier' => 'multi-node-sync', 'version' => '1.0.0', 'enabled' => true]);
        $repository = $this->app->make(ExtensionRepository::class);
        $repository->flushDiscovery();
        $this->app->make(ExtensionProviderLoader::class)->registerProviders($repository->enabled());

        $error = Extension::query()->where('identifier', 'multi-node-sync')->value('error');
        if ($error !== null) {
            throw new RuntimeException("multi-node-sync failed to load: $error");
        }
    }

    protected function tearDown(): void
    {
        $this->app->make(ExtensionRepository::class)->flushDiscovery();
        File::deleteDirectory($this->assets);

        parent::tearDown();
    }

    /** @param array<string, mixed> $values */
    protected function configure(array $values): void
    {
        $this->app->make(ExtensionSettingsRegistry::class)->get('multi-node-sync')->update($values);
    }

    protected function settings(): MultiNodeSyncSettings
    {
        return MultiNodeSyncSettings::fromRegistry($this->app->make(ExtensionSettingsRegistry::class));
    }

    /** A node that can be a migration target: Panel nodes always belong to a location. @param array<string, mixed> $attributes */
    protected function nodeModel(array $attributes = []): Node
    {
        return Node::factory()->create(array_merge(['location_id' => Location::factory()->create()->id], $attributes));
    }

    protected function actingAsAdmin(): User
    {
        $admin = User::factory()->create(['root_admin' => true]);
        $this->actingAs($admin);

        return $admin;
    }
}

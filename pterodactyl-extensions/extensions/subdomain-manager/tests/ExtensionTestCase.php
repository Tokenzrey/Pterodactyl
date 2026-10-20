<?php

declare(strict_types=1);

namespace SubdomainManager\Tests;

use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\File;
use Illuminate\Testing\TestResponse;
use Pterodactyl\Models\Extension;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionProviderLoader;
use Pterodactyl\Services\Extensions\ExtensionRepository;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use Pterodactyl\Tests\Integration\IntegrationTestCase;
use RuntimeException;
use SubdomainManager\Support\SubdomainSettings;

/**
 * Boots the Panel with the subdomain-manager extension installed and enabled from its source directory,
 * exactly as the loader would, so the provider, routes, settings and listeners are the real ones.
 */
abstract class ExtensionTestCase extends IntegrationTestCase
{
    use DatabaseTransactions;

    protected const TOKEN = 'cf-test-token-DO-NOT-LEAK-0123456789';

    private string $assets;

    protected function setUp(): void
    {
        parent::setUp();

        $this->assets = sys_get_temp_dir().'/subdomain-manager-assets-'.uniqid();
        config([
            'extensions.enabled' => true,
            'extensions.directory' => '/ext-src',
            'extensions.assets_directory' => $this->assets,
        ]);
        $this->app->forgetInstance(ExtensionRepository::class);
        $this->app->forgetInstance(ExtensionProviderLoader::class);

        Extension::query()->create(['identifier' => 'subdomain-manager', 'version' => '1.0.0', 'enabled' => true]);
        $repository = $this->app->make(ExtensionRepository::class);
        $repository->flushDiscovery();
        $this->app->make(ExtensionProviderLoader::class)->registerProviders($repository->enabled());

        // The Panel records a failed boot on the extension row and carries on; a test must not.
        $error = Extension::query()->where('identifier', 'subdomain-manager')->value('error');
        if ($error !== null) {
            throw new RuntimeException("subdomain-manager failed to load: $error");
        }
    }

    protected function tearDown(): void
    {
        $this->app->make(ExtensionRepository::class)->flushDiscovery();
        File::deleteDirectory($this->assets);

        parent::tearDown();
    }

    /** Saves settings the way the admin form does (the token is encrypted at rest). @param array<string, mixed> $values */
    protected function configure(array $values): void
    {
        $this->app->make(ExtensionSettingsRegistry::class)->get('subdomain-manager')->update($values);
    }

    /** A working setup: token, one domain, an address, SRV on. @param array<string, mixed> $more */
    protected function configureCloudflare(array $more = []): void
    {
        $this->configure([
            'cloudflare_token' => self::TOKEN,
            'domains' => ['mc.example.com:'.FakeCloudflare::ZONE],
            'target_ipv4' => '203.0.113.10',
            'srv_enabled' => true,
            'srv_port' => 25565,
            'ttl' => 120,
            ...$more,
        ]);
    }

    protected function settings(): SubdomainSettings
    {
        return SubdomainSettings::fromRegistry($this->app->make(ExtensionSettingsRegistry::class));
    }

    protected function actingAsAdmin(): User
    {
        $admin = User::factory()->create(['root_admin' => true]);
        $this->actingAs($admin);

        return $admin;
    }

    /** The admin form payload for a server's subdomain. @param array<string, mixed> $subdomain */
    protected function detailsPayload(Server $server, array $subdomain): array
    {
        return ['name' => $server->name, 'owner_id' => $server->owner_id, 'extensions' => ['subdomain-manager' => $subdomain]];
    }

    /** @param array<string, mixed> $subdomain */
    protected function saveSubdomain(Server $server, array $subdomain): TestResponse
    {
        return $this->putJson(route('api.admin.servers.details', ['server' => $server->id]), $this->detailsPayload($server, $subdomain));
    }
}

<?php

declare(strict_types=1);

use Illuminate\Support\Str;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\Server;
use Pterodactyl\Tests\Support\Fakes\FakeDaemonServer;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-R4, FR-R5, AC-R7 (the screens' data): the admin form, the settings the page reads, and the records list say
// whether a name will be routed, using the same rules as games sync. Nothing here calls Cloudflare.

beforeEach(function (): void {
    $this->actingAsAdmin();
    $this->configureCloudflare(['mode' => 'routed']);
    $this->daemon = new FakeDaemonServer; // before the Cloudflare fake: both are added to the same HTTP client
    $this->cf = (new FakeCloudflare)->install(fresh: false);
});

/** A Minecraft server on a loopback allocation, the shape games sync routes. */
function viewMinecraftServer(string $name, array $attributes = []): Server
{
    $egg = Egg::query()->where('name', 'Bungeecord')->firstOrFail()->replicate();
    $egg->name = 'Minecraft Test';
    $egg->uuid = (string) Str::uuid();
    $egg->save();

    $server = test()->createServerModel(['name' => $name, 'egg_id' => $egg->id, ...$attributes]);
    $server->allocation->update(['ip' => '127.0.0.1']);

    return $server->fresh(['allocation', 'egg']);
}

test('the config endpoint tells the form which mode is set', function (): void {
    $this->getJson('/api/admin/extensions/subdomain-manager/config')->assertOk()->assertJsonPath('mode', 'routed');

    $this->configureCloudflare(['mode' => 'per_port']);
    $this->getJson('/api/admin/extensions/subdomain-manager/config')->assertOk()->assertJsonPath('mode', 'per_port');
});

test('AC-R7 FR-R5 the admin form of a routable Minecraft server says it will be routed, with its host name', function (): void {
    $server = viewMinecraftServer('Kampung');

    $this->getJson(route('api.admin.servers.view', ['server' => $server->id]))->assertOk()
        ->assertJsonPath('attributes.extensions.subdomain-manager.mode', 'routed')
        ->assertJsonPath('attributes.extensions.subdomain-manager.routing_state', 'ready')
        ->assertJsonPath('attributes.extensions.subdomain-manager.routing_reason', null);
});

test('AC-R7 the admin form says why a server is not routed', function (): void {
    $server = viewMinecraftServer('Kampung');
    $server->allocation->update(['ip' => '0.0.0.0']);

    $this->getJson(route('api.admin.servers.view', ['server' => $server->id]))->assertOk()
        ->assertJsonPath('attributes.extensions.subdomain-manager.routing_state', 'invalid')
        ->assertJsonPath('attributes.extensions.subdomain-manager.routing_reason', 'the allocation is 0.0.0.0, not 127.0.0.1');
});

test('per-port mode shows no routing status, because there is no router in that mode', function (): void {
    $this->configureCloudflare(['mode' => 'per_port']);
    $server = viewMinecraftServer('Kampung');

    $this->getJson(route('api.admin.servers.view', ['server' => $server->id]))->assertOk()
        ->assertJsonPath('attributes.extensions.subdomain-manager.mode', 'per_port')
        ->assertJsonPath('attributes.extensions.subdomain-manager.routing_state', null);
});

test('the records list gives every row its routing status, from the server behind it', function (): void {
    $server = viewMinecraftServer('Kampung');
    Record::query()->create([
        'server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE,
    ]);

    $this->getJson('/api/admin/extensions/subdomain-manager/records')->assertOk()
        ->assertJsonPath('data.0.routing.state', 'ready')
        ->assertJsonPath('data.0.address', 'kampung.mc.example.com');
});

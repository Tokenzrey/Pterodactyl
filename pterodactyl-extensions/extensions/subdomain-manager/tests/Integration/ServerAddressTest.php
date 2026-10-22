<?php

declare(strict_types=1);

use Pterodactyl\Models\User;
use Pterodactyl\Tests\Support\Fakes\FakeDaemonServer;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// The owner's view of the address: the server console shows it to whoever may open the server. Nothing secret is
// answered (no token, no zone id), and nobody else can read it.

beforeEach(function (): void {
    $this->configureCloudflare(['mode' => 'routed']);
    $this->daemon = new FakeDaemonServer; // before the Cloudflare fake: both are added to the same HTTP client
    $this->cf = (new FakeCloudflare)->install(fresh: false);
});

function addressUrl(object $server): string
{
    return "/api/client/servers/{$server->uuid}/extensions/subdomain-manager/address";
}

test('the owner gets the address of their server and the routing answer for it', function (): void {
    $owner = User::factory()->create(['root_admin' => false]);
    $server = test()->createServerModel(['owner_id' => $owner->id, 'name' => 'Kampung']);
    Record::query()->create([
        'server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE,
    ]);

    $this->actingAs($owner)->getJson(addressUrl($server))->assertOk()
        ->assertJsonPath('address', 'kampung.mc.example.com')
        ->assertJsonPath('status', 'active')
        ->assertJsonPath('mode', 'routed')
        ->assertJsonPath('needs_port', false);
});

test('a server with no subdomain answers with no address, not an error', function (): void {
    $owner = User::factory()->create(['root_admin' => false]);
    $server = test()->createServerModel(['owner_id' => $owner->id]);

    $this->actingAs($owner)->getJson(addressUrl($server))->assertOk()
        ->assertJsonPath('address', null)
        ->assertJsonPath('status', null);
});

test('per-port without SRV says the port must be typed, because the name alone does not carry it', function (): void {
    $this->configureCloudflare(['mode' => 'per_port', 'srv_enabled' => false]);
    $owner = User::factory()->create(['root_admin' => false]);
    $server = test()->createServerModel(['owner_id' => $owner->id]);
    Record::query()->create([
        'server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE,
    ]);

    $this->actingAs($owner)->getJson(addressUrl($server))->assertOk()
        ->assertJsonPath('mode', 'per_port')
        ->assertJsonPath('needs_port', true);
});

test('someone who cannot open the server gets no address', function (): void {
    $owner = User::factory()->create(['root_admin' => false]);
    $stranger = User::factory()->create(['root_admin' => false]);
    $server = test()->createServerModel(['owner_id' => $owner->id]);
    Record::query()->create([
        'server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE,
    ]);

    // The Panel answers 404 for a server the user may not open, so the server does not even show that it exists.
    $this->actingAs($stranger)->getJson(addressUrl($server))->assertNotFound()->assertJsonMissing(['address' => 'kampung.mc.example.com']);
});

test('the answer carries no token and no zone id', function (): void {
    $owner = User::factory()->create(['root_admin' => false]);
    $server = test()->createServerModel(['owner_id' => $owner->id]);
    Record::query()->create([
        'server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE,
    ]);

    $body = $this->actingAs($owner)->getJson(addressUrl($server))->assertOk()->getContent();

    expect($body)->not->toContain(self::TOKEN)->not->toContain(FakeCloudflare::ZONE);
});

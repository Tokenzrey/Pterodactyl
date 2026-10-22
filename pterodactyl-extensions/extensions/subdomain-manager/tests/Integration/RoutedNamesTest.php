<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Str;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\Server;
use Pterodactyl\Tests\Support\Fakes\FakeDaemonServer;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-R2, FR-R6, AC-R1, AC-R5, EC-R1: in routed mode the label is the slug of the server's name, and a name that gives
// the same slug as another Minecraft server is refused at save time, with that server's name in the message.

beforeEach(function (): void {
    $this->actingAsAdmin();
    $this->configureCloudflare(['mode' => 'routed']);
    $this->daemon = new FakeDaemonServer; // before the Cloudflare fake: both are added to the same HTTP client
    $this->cf = (new FakeCloudflare)->install(fresh: false);
    Bus::fake([SyncRecord::class]);
});

/** A copy of the Bungeecord egg renamed to a Minecraft one. The name decides what counts as a Minecraft server. */
function routedMinecraftEgg(): Egg
{
    $base = Egg::query()->where('name', 'Bungeecord')->firstOrFail();
    $egg = $base->replicate();
    $egg->name = 'Minecraft Test';
    $egg->uuid = (string) Str::uuid();
    $egg->save();

    return $egg;
}

test('AC-R1 routed: the label is the slug of the name, whatever was typed into the field', function (): void {
    $server = $this->createServerModel(['name' => 'Kampung 2!', 'egg_id' => routedMinecraftEgg()->id]);

    $this->saveSubdomain($server, ['label' => 'anything else', 'domain' => 'mc.example.com'])->assertOk()
        ->assertJsonPath('attributes.extensions.subdomain-manager.label', 'kampung-2')
        ->assertJsonPath('attributes.extensions.subdomain-manager.fqdn', 'kampung-2.mc.example.com');

    expect(Record::query()->where('server_uuid', $server->uuid)->sole()->label)->toBe('kampung-2');
});

test('FR-R6 AC-R5 a name whose slug another Minecraft server already has is refused, and the message names that server', function (): void {
    $egg = routedMinecraftEgg();
    $this->createServerModel(['name' => 'Survival Utama', 'egg_id' => $egg->id]);
    $server = $this->createServerModel(['name' => 'survival-utama', 'egg_id' => $egg->id]);

    $response = $this->saveSubdomain($server, ['label' => 'x', 'domain' => 'mc.example.com'])->assertUnprocessable();

    expect(collect($response->json('errors'))->pluck('detail')->join(' '))->toContain('Survival Utama');
    expect(Record::query()->where('server_uuid', $server->uuid)->exists())->toBeFalse();
});

test('FR-R6 the same server saved again is not a conflict with itself', function (): void {
    $server = $this->createServerModel(['name' => 'Survival Utama', 'egg_id' => routedMinecraftEgg()->id]);

    $this->saveSubdomain($server, ['label' => 'x', 'domain' => 'mc.example.com'])->assertOk();
    $this->saveSubdomain($server, ['label' => 'x', 'domain' => 'mc.example.com'])->assertOk();

    expect(Record::query()->where('server_uuid', $server->uuid)->sole()->label)->toBe('survival-utama');
});

test('FR-R6 a server that is not Minecraft does not block a Minecraft name, because games sync does not route it', function (): void {
    $this->createServerModel(['name' => 'Survival Utama']); // the default egg is Bungeecord: not a Minecraft egg
    $server = $this->createServerModel(['name' => 'Survival Utama', 'egg_id' => routedMinecraftEgg()->id]);

    $this->saveSubdomain($server, ['label' => 'x', 'domain' => 'mc.example.com'])->assertOk();
});

test('EC-R1 a name that gives no host name is refused with the reason, and no record is made', function (): void {
    $server = $this->createServerModel(['name' => '!!!', 'egg_id' => routedMinecraftEgg()->id]);

    $response = $this->saveSubdomain($server, ['label' => 'x', 'domain' => 'mc.example.com'])->assertUnprocessable();

    expect(collect($response->json('errors'))->pluck('detail')->join(' '))->toContain('host name');
    expect(Record::query()->where('server_uuid', $server->uuid)->exists())->toBeFalse();
});

test('per-port mode keeps the typed label and the old rules', function (): void {
    $this->configureCloudflare(['mode' => 'per_port']);
    $server = $this->createServerModel(['name' => 'Kampung 2!', 'egg_id' => routedMinecraftEgg()->id]);

    $this->saveSubdomain($server, ['label' => 'my-label', 'domain' => 'mc.example.com'])->assertOk()
        ->assertJsonPath('attributes.extensions.subdomain-manager.label', 'my-label');

    $this->saveSubdomain($server, ['label' => 'Not A Label', 'domain' => 'mc.example.com'])->assertUnprocessable();
});

test('an empty label saves no record and leaves the server name alone', function (): void {
    $server = $this->createServerModel(['name' => 'Kampung', 'egg_id' => routedMinecraftEgg()->id]);

    $this->saveSubdomain($server, ['label' => '', 'domain' => ''])->assertOk();

    expect(Record::query()->where('server_uuid', $server->uuid)->exists())->toBeFalse();
    expect($server->fresh()->name)->toBe('Kampung');
});

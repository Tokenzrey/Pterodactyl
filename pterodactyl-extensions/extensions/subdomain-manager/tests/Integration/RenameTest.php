<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Event;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;
use Pterodactyl\Events\Server\Updating;
use Pterodactyl\Models\Egg;
use Pterodactyl\Tests\Support\Fakes\FakeDaemonServer;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-R9, FR-R10, AC-R6, EC-R3: renaming a Minecraft server in routed mode moves its host name, and a rename that
// would take another server's host name, or leave the name without one, is refused before anything is saved.

beforeEach(function (): void {
    $this->actingAsAdmin();
    $this->configureCloudflare(['mode' => 'routed']);
    $this->daemon = new FakeDaemonServer; // before the Cloudflare fake: both are added to the same HTTP client
    $this->cf = (new FakeCloudflare)->install(fresh: false);
});

/** A copy of the Bungeecord egg renamed to a Minecraft one: the name is what makes a server routable. */
function renameMinecraftEgg(): Egg
{
    $base = Egg::query()->where('name', 'Bungeecord')->firstOrFail();
    $egg = $base->replicate();
    $egg->name = 'Minecraft Test';
    $egg->uuid = (string) Str::uuid();
    $egg->save();

    return $egg;
}

test('verification: an exception thrown by an Updating listener stops the rename, so the refusal can be an exception', function (): void {
    $server = test()->createServerModel(['name' => 'Kampung']);
    Event::listen(Updating::class, fn () => throw new RuntimeException('stop'));

    expect(fn () => $server->update(['name' => 'Kampung Baru']))->toThrow(RuntimeException::class);
    expect($server->fresh()->name)->toBe('Kampung');
});

test('FR-R10 AC-R6 a rename to a host name another Minecraft server has is refused, and the name stays', function (): void {
    $egg = renameMinecraftEgg();
    $this->createServerModel(['name' => 'Survival Utama', 'egg_id' => $egg->id]);
    $kampung = $this->createServerModel(['name' => 'Kampung', 'egg_id' => $egg->id]);

    expect(fn () => $kampung->update(['name' => 'survival-utama']))->toThrow(ValidationException::class);
    expect($kampung->fresh()->name)->toBe('Kampung');
});

test('EC-R1 a rename to a name that gives no host name is refused', function (): void {
    $server = $this->createServerModel(['name' => 'Kampung', 'egg_id' => renameMinecraftEgg()->id]);

    expect(fn () => $server->update(['name' => '!!!']))->toThrow(ValidationException::class);
    expect($server->fresh()->name)->toBe('Kampung');
});

test('EC-R3 a rename that keeps the host name changes nothing at Cloudflare', function (): void {
    $server = $this->createServerModel(['name' => 'Kampung', 'egg_id' => renameMinecraftEgg()->id]);
    $record = Record::query()->create([
        'server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE, 'synced_name' => 'kampung.mc.example.com',
    ]);

    $server->update(['name' => 'kampung!']);

    expect($this->cf->calls)->toBe([])->and($record->refresh()->label)->toBe('kampung');
});

test('FR-R9 a valid rename moves the label, and the old SRV record is replaced by one for the new name', function (): void {
    $server = $this->createServerModel(['name' => 'Kampung', 'egg_id' => renameMinecraftEgg()->id]);
    $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
    $record = Record::query()->where('server_uuid', $server->uuid)->sole();
    SyncRecord::dispatchSync($record->id);
    expect($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1);

    $server->update(['name' => 'Kampung Baru']);
    SyncRecord::dispatchSync($record->id); // the job the rename queues after commit; running it again changes nothing

    $record->refresh();
    expect($record->label)->toBe('kampung-baru')
        ->and($record->status)->toBe(Record::ACTIVE)
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toBe([])
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung-baru.mc.example.com')[0]['data']['port'])->toBe(25565);
});

test('a rename of a server with no subdomain makes no record and no Cloudflare call', function (): void {
    $server = $this->createServerModel(['name' => 'Kampung', 'egg_id' => renameMinecraftEgg()->id]);

    $server->update(['name' => 'Kampung Baru']);

    expect(Record::query()->where('server_uuid', $server->uuid)->exists())->toBeFalse()->and($this->cf->calls)->toBe([]);
});

test('per-port mode: a rename does not touch the label, because the label is not the name there', function (): void {
    $this->configureCloudflare(['mode' => 'per_port', 'srv_port' => 25600]);
    $server = $this->createServerModel(['name' => 'Kampung', 'egg_id' => renameMinecraftEgg()->id]);
    $this->saveSubdomain($server, ['label' => 'my-label', 'domain' => 'mc.example.com'])->assertOk();

    $server->update(['name' => 'Kampung Baru']);

    expect(Record::query()->where('server_uuid', $server->uuid)->sole()->label)->toBe('my-label');
});

test('only Minecraft servers are routed, so a non-Minecraft server does not block a rename to a Minecraft name', function (): void {
    $egg = renameMinecraftEgg();
    $this->createServerModel(['name' => 'Survival Utama', 'egg_id' => $egg->id]);
    $other = $this->createServerModel(['name' => 'Notes']); // the default Bungeecord egg: not Minecraft

    $other->update(['name' => 'survival-utama']);

    expect($other->fresh()->name)->toBe('survival-utama');
});

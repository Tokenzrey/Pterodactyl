<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Bus;
use Pterodactyl\Tests\Support\Fakes\FakeDaemonServer;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-R7, FR-R8, AC-R3, AC-R4, Fokus-2: the resync command, and the five-minute reconcile that carries a mode change
// to the records that already exist (the Panel emits no event for extension settings, so there is no instant hook).

beforeEach(function (): void {
    $this->actingAsAdmin();
    $this->configureCloudflare(['mode' => 'per_port', 'srv_port' => 25600]);
    $this->daemon = new FakeDaemonServer; // before the Cloudflare fake: both are added to the same HTTP client
    $this->cf = (new FakeCloudflare)->install(fresh: false);
});

/** A server with a subdomain made while the mode was per-port, so its SRV record carries port 25600. */
function resyncServerWithSubdomain(string $label): Record
{
    $server = test()->createServerModel();
    test()->saveSubdomain($server, ['label' => $label, 'domain' => 'mc.example.com'])->assertOk();

    return Record::query()->where('server_uuid', $server->uuid)->sole();
}

test('the resync command queues one job for every row except the ones being removed', function (): void {
    // Rows are written directly: the form queues its job after commit, and a test transaction never commits.
    $row = fn (string $label, string $status): Record => Record::query()->create([
        'server_id' => null, 'server_uuid' => (string) Str::uuid(), 'domain' => 'mc.example.com', 'label' => $label,
        'zone_id' => FakeCloudflare::ZONE, 'status' => $status,
    ]);
    $active = $row('one', Record::ACTIVE);
    $pending = $row('two', Record::PENDING);
    $deleting = $row('three', Record::DELETING);
    Bus::fake([SyncRecord::class]);

    $this->artisan('subdomain-manager:resync')->assertSuccessful();

    Bus::assertDispatchedTimes(SyncRecord::class, 2);
    Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $active->id);
    Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $pending->id);
    Bus::assertNotDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $deleting->id);
});

test('AC-R3 after the mode changes to routed, resync replaces the SRV record of an active row with port 25565', function (): void {
    $record = resyncServerWithSubdomain('kampung');
    expect($record->refresh()->srv_port)->toBe(25600);
    $this->configureCloudflare(['mode' => 'routed']);
    $this->cf->calls = [];

    $this->artisan('subdomain-manager:resync')->assertSuccessful();

    $record->refresh();
    expect($record->srv_port)->toBe(25565)
        ->and($record->status)->toBe(Record::ACTIVE)
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['data']['port'])->toBe(25565)
        ->and($this->cf->count('POST', 'A'))->toBe(0);
});

test('AC-R4 resync of an active row that is already on the right port makes no Cloudflare call', function (): void {
    resyncServerWithSubdomain('kampung');
    $this->configureCloudflare(['mode' => 'per_port', 'srv_port' => 25600]); // unchanged
    $this->cf->calls = [];

    $this->artisan('subdomain-manager:resync')->assertSuccessful();

    expect($this->cf->calls)->toBe([]);
});

test('FR-R7 the five-minute reconcile carries a mode change to the existing records too, without any manual step', function (): void {
    $record = resyncServerWithSubdomain('kampung');
    $this->configureCloudflare(['mode' => 'routed']);

    $this->artisan('subdomain-manager:reconcile')->assertSuccessful();

    expect($record->refresh()->srv_port)->toBe(25565)
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['data']['port'])->toBe(25565);
});

test('a row that is not active and not waiting is not touched by the reconcile', function (): void {
    $record = resyncServerWithSubdomain('kampung');
    $record->update(['status' => Record::DELETING]);
    $this->configureCloudflare(['mode' => 'routed']);
    $this->cf->calls = [];

    $this->artisan('subdomain-manager:reconcile')->assertSuccessful();

    expect($this->cf->calls)->toBe([])->and($record->refresh()->srv_port)->toBe(25600);
});

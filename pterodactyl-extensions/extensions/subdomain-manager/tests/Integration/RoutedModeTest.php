<?php

declare(strict_types=1);

use Illuminate\Http\Client\Factory;
use Illuminate\Support\Str;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\CloudflareClient;
use SubdomainManager\Support\CloudflareException;
use SubdomainManager\Support\RecordSyncer;
use SubdomainManager\Support\SyncConfig;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-R3, FR-R8, AC-R2 to AC-R4, Fokus-2 and Fokus-3 (routed mode): one port, no A record per server, and an SRV
// record that is replaced when its port changes. Helper names are prefixed: RecordSyncerTest.php owns the others.

function routedRow(array $override = []): Record
{
    return Record::query()->create($override + [
        'server_id' => null,
        'server_uuid' => (string) Str::uuid(),
        'domain' => 'mc.example.com',
        'label' => 'kampung',
        'zone_id' => FakeCloudflare::ZONE,
        'status' => Record::PENDING,
    ]);
}

function routedSyncer(bool $routed = true, int $port = 25565): RecordSyncer
{
    $config = new SyncConfig(['mc.example.com' => FakeCloudflare::ZONE], '203.0.113.10', true, $port, 120, $routed);

    return new RecordSyncer(new CloudflareClient(app(Factory::class), 'cf-test-token-DO-NOT-LEAK'), $config);
}

beforeEach(function (): void {
    $this->cf = (new FakeCloudflare)->install();
});

test('AC-R2 routed: a new server gets an SRV record on port 25565 and no A record of its own', function (): void {
    $record = routedRow();

    routedSyncer()->sync($record);

    expect($this->cf->count('POST', 'A'))->toBe(0)
        ->and($this->cf->named('A', 'kampung.mc.example.com'))->toBe([])
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['data']['port'])->toBe(25565);

    $record->refresh();
    expect($record->status)->toBe('active')
        ->and($record->a_record_id)->toBeNull()
        ->and($record->srv_port)->toBe(25565)
        ->and($record->synced_name)->toBe('kampung.mc.example.com');
});

test('routed: a foreign A record under the name is still a conflict, because it would take the name away from the router', function (): void {
    $foreign = $this->cf->seed('A', 'kampung.mc.example.com', ['content' => '198.51.100.7']);
    $record = routedRow();

    routedSyncer()->sync($record);

    $record->refresh();
    expect($record->status)->toBe('failed')->and($record->last_error)->toStartWith('conflict:')
        ->and($this->cf->count('POST'))->toBe(0)
        ->and($this->cf->named('A', 'kampung.mc.example.com')[0]['id'])->toBe($foreign);
});

test('AC-R3 FR-R8: an SRV record made for another port is removed by id and replaced with port 25565', function (): void {
    $record = routedRow();
    routedSyncer(routed: false, port: 25600)->sync($record);
    [$oldSrv, $a] = [$record->refresh()->srv_record_id, $record->a_record_id];
    expect($record->srv_port)->toBe(25600);
    $record->update(['status' => 'pending']);
    $this->cf->calls = [];

    routedSyncer()->sync($record);

    $trace = $this->cf->trace();
    expect($trace[0])->toBe("DELETE $oldSrv")
        ->and($trace)->toContain('POST SRV')
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['data']['port'])->toBe(25565);
    $record->refresh();
    expect($record->srv_port)->toBe(25565)
        ->and($record->srv_record_id)->not->toBe($oldSrv)
        ->and($record->a_record_id)->toBe($a); // the A record of the per-port era stays (Q6)
});

test('AC-R4 FR-R8: an SRV record that already has the right port is left alone, with no Cloudflare call', function (): void {
    $record = routedRow();
    routedSyncer()->sync($record);
    $record->update(['status' => 'pending']);
    $this->cf->calls = [];

    routedSyncer()->sync($record);

    expect($this->cf->calls)->toBe([])->and($record->refresh()->status)->toBe('active');
});

test('FR-R8 a row from before the port was stored is replaced once, so it ends up on the wanted port', function (): void {
    $record = routedRow(['status' => 'pending']);
    $record->update(['srv_record_id' => $this->cf->seed('SRV', '_minecraft._tcp.kampung.mc.example.com', ['data' => ['port' => 25600]]), 'synced_name' => 'kampung.mc.example.com', 'zone_id' => FakeCloudflare::ZONE]);
    $this->cf->calls = [];

    routedSyncer()->sync($record);

    // DELETE calls carry no record type, so the count is over all deletes (the only one here is the SRV record).
    expect($this->cf->count('DELETE'))->toBe(1)->and($this->cf->count('POST', 'SRV'))->toBe(1);
    expect($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1);
});

test('Fokus-3 a failed removal of the old SRV keeps its id, so nothing is orphaned and the retry finishes the job', function (): void {
    $record = routedRow();
    routedSyncer(routed: false, port: 25600)->sync($record);
    $oldSrv = $record->refresh()->srv_record_id;
    $record->update(['status' => 'pending']);
    $this->cf->failNext('DELETE', 503); // DELETE calls carry no record type: this fails the first delete

    expect(fn () => routedSyncer()->sync($record))->toThrow(CloudflareException::class);
    expect($record->refresh()->srv_record_id)->toBe($oldSrv)
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['id'])->toBe($oldSrv);

    routedSyncer()->sync($record);

    expect($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1)
        ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['data']['port'])->toBe(25565);
});

test('Fokus-3 a failed creation of the new SRV leaves no stray record, and the retry creates exactly one', function (): void {
    $record = routedRow();
    routedSyncer(routed: false, port: 25600)->sync($record);
    $record->update(['status' => 'pending']);
    $this->cf->failNext('POST', 503, 'SRV');

    expect(fn () => routedSyncer()->sync($record))->toThrow(CloudflareException::class);
    expect($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toBe([])
        ->and($record->refresh()->srv_record_id)->toBeNull()
        ->and($record->srv_port)->toBeNull();

    routedSyncer()->sync($record);

    expect($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1)
        ->and($record->refresh()->status)->toBe('active');
});

test('the per-port mode keeps making A records, exactly as before', function (): void {
    $record = routedRow();

    routedSyncer(routed: false, port: 25565)->sync($record);

    expect($this->cf->count('POST', 'A'))->toBe(1)->and($record->refresh()->a_record_id)->not->toBeNull();
});

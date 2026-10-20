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

// FR-S4 to FR-S8, FR-S13, AC-S2 to AC-S8, AC-S14, AC-S15, EC-S2 to EC-S10, Fokus-4: the syncer against an
// in-memory Cloudflare, so the assertions are about the DNS state that is left, not about canned replies.

const ZONE = FakeCloudflare::ZONE;

function row(array $override = []): Record
{
    return Record::query()->create($override + [
        'server_id' => null,
        'server_uuid' => (string) Str::uuid(),
        'domain' => 'mc.example.com',
        'label' => 'kampung',
        'zone_id' => ZONE,
        'status' => Record::PENDING,
    ]);
}

function testConfig(array $override = []): SyncConfig
{
    $o = $override + ['domains' => ['mc.example.com' => ZONE, 'play.example.org' => FakeCloudflare::OTHER_ZONE], 'ip' => '203.0.113.10', 'srv' => true, 'port' => 25565, 'ttl' => 120];

    return new SyncConfig($o['domains'], $o['ip'], $o['srv'], $o['port'], $o['ttl']);
}

function syncer(array $config = [], bool $withToken = true): RecordSyncer
{
    return new RecordSyncer($withToken ? new CloudflareClient(app(Factory::class), 'cf-test-token-DO-NOT-LEAK') : null, testConfig($config));
}

beforeEach(function (): void {
    $this->cf = (new FakeCloudflare)->install();
});

describe('creating (AC-S2, AC-S14, EC-S10)', function (): void {
    test('AC-S2 an A and an SRV record are made with the exact payloads, ids stored, status active', function (): void {
        $record = row();

        syncer()->sync($record);

        $a = $this->cf->named('A', 'kampung.mc.example.com');
        $srv = $this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com');
        expect($a)->toHaveCount(1)->and($srv)->toHaveCount(1);
        expect($a[0])->toMatchArray(['type' => 'A', 'name' => 'kampung.mc.example.com', 'content' => '203.0.113.10', 'ttl' => 120, 'proxied' => false, 'comment' => 'ptero subdomain-manager server='.$record->server_uuid]);
        expect($srv[0])->toMatchArray(['type' => 'SRV', 'ttl' => 120, 'data' => ['priority' => 0, 'weight' => 5, 'port' => 25565, 'target' => 'kampung.mc.example.com']]);

        $record->refresh();
        expect($record->status)->toBe('active')
            ->and($record->a_record_id)->toBe($a[0]['id'])
            ->and($record->srv_record_id)->toBe($srv[0]['id'])
            ->and($record->synced_name)->toBe('kampung.mc.example.com')
            ->and($record->zone_id)->toBe(ZONE)
            ->and($record->last_error)->toBeNull()
            ->and($record->attempts)->toBe(0);
    });

    test('AC-S14 srv_port 0 takes the port of the primary allocation, another value is used as is', function (): void {
        $server = $this->createServerModel();
        $port = $server->allocation->port;

        syncer(['port' => 0])->sync(row(['server_id' => $server->id, 'label' => 'fromalloc']));
        syncer(['port' => 30000])->sync(row(['server_id' => $server->id, 'label' => 'fixed']));

        expect($this->cf->named('SRV', '_minecraft._tcp.fromalloc.mc.example.com')[0]['data']['port'])->toBe($port)
            ->and($this->cf->named('SRV', '_minecraft._tcp.fixed.mc.example.com')[0]['data']['port'])->toBe(30000);
    });

    test('EC-S10 srv_port 0 and no allocation: the SRV record is skipped with a note and the A record stands', function (): void {
        $record = row(['server_id' => null]);

        syncer(['port' => 0])->sync($record);

        $record->refresh();
        expect($record->status)->toBe('active')
            ->and($record->srv_record_id)->toBeNull()
            ->and($record->last_error)->toContain('SRV record skipped');
        expect($this->cf->count('POST', 'SRV'))->toBe(0)->and($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1);
    });

    test('with SRV switched off only the A record is made', function (): void {
        $record = row();

        syncer(['srv' => false])->sync($record);

        expect($this->cf->count('POST', 'SRV'))->toBe(0)
            ->and($record->refresh()->srv_record_id)->toBeNull()
            ->and($record->status)->toBe('active');
    });

    test('switching SRV off later removes the SRV record, by id', function (): void {
        $record = row();
        syncer()->sync($record);
        $srvId = $record->refresh()->srv_record_id;
        $record->update(['status' => 'pending']);

        syncer(['srv' => false])->sync($record);

        expect($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toBe([])
            ->and($record->refresh()->srv_record_id)->toBeNull()
            ->and($this->cf->trace())->toContain('DELETE '.$srvId);
    });

    test('an active row is left alone: no Cloudflare call at all', function (): void {
        $record = row(['status' => 'active']);

        syncer()->sync($record);

        expect($this->cf->calls)->toBe([]);
    });

    test('syncing the same pending row twice never makes a second record (EC-S9)', function (): void {
        $record = row();

        syncer()->sync($record);
        $record->update(['status' => 'pending']); // as if a duplicate job ran after the first finished
        syncer()->sync($record);

        expect($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1)
            ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1)
            ->and($this->cf->count('POST'))->toBe(2);
    });
});

describe('retries (AC-S3, EC-S2, FR-S8)', function (): void {
    test('AC-S3 A made, SRV fails for now, retry: the A record is not made twice and the SRV record is made', function (): void {
        $record = row();
        $this->cf->failNext('POST', 503, 'SRV');

        expect(fn () => syncer()->sync($record))->toThrow(CloudflareException::class);

        $record->refresh();
        expect($record->status)->toBe('pending')
            ->and($record->a_record_id)->not->toBeNull()
            ->and($record->srv_record_id)->toBeNull()
            ->and($record->attempts)->toBe(1)
            ->and($record->last_error)->toBe('1000: boom');

        syncer()->sync($record);

        $record->refresh();
        expect($record->status)->toBe('active')->and($record->attempts)->toBe(0)->and($record->last_error)->toBeNull();
        expect($this->cf->count('POST', 'A'))->toBe(1)->and($this->cf->count('POST', 'SRV'))->toBe(2);
        expect($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1)->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1);
    });

    test('EC-S2 429 is retryable: it is thrown for the queue and the row stays pending', function (): void {
        $record = row();
        $this->cf->failNext('GET', 429, 'A', 971, 'Rate limited');

        expect(fn () => syncer()->sync($record))->toThrow(CloudflareException::class);

        expect($record->refresh()->status)->toBe('pending')->and($record->last_error)->toBe('971: Rate limited');
    });

    test('a failed row is tried again like a pending one (reconcile relies on this)', function (): void {
        $record = row(['status' => 'failed', 'last_error' => 'something old']);

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('active')->and($record->last_error)->toBeNull();
    });
});

describe('conflicts (AC-S4, FR-S5)', function (): void {
    test('AC-S4 a record of that name that is not ours: failed with a conflict, nothing created, nothing touched', function (): void {
        $foreign = $this->cf->seed('A', 'kampung.mc.example.com', ['content' => '198.51.100.7']);
        $record = row();

        syncer()->sync($record);

        $record->refresh();
        expect($record->status)->toBe('failed')
            ->and($record->last_error)->toStartWith('conflict:')
            ->and($record->a_record_id)->toBeNull();
        expect($this->cf->count('POST'))->toBe(0)->and($this->cf->count('DELETE'))->toBe(0);
        expect($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1)->and($this->cf->named('A', 'kampung.mc.example.com')[0]['id'])->toBe($foreign);
    });

    test('a foreign SRV record is a conflict too; our A record stays recorded and the foreign one is untouched', function (): void {
        $foreign = $this->cf->seed('SRV', '_minecraft._tcp.kampung.mc.example.com', ['data' => ['port' => 1]]);
        $record = row();

        syncer()->sync($record);

        $record->refresh();
        expect($record->status)->toBe('failed')->and($record->last_error)->toStartWith('conflict:')
            ->and($record->a_record_id)->not->toBeNull();
        expect($this->cf->count('DELETE'))->toBe(0)->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com')[0]['id'])->toBe($foreign);
    });

    test('once the stranger is gone the next sync succeeds', function (): void {
        $foreign = $this->cf->seed('A', 'kampung.mc.example.com');
        $record = row();
        syncer()->sync($record);
        unset($this->cf->zones[ZONE][$foreign]);

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('active');
    });

    test('the conflict check compares names without regard to case', function (): void {
        $this->cf->seed('A', 'KAMPUNG.mc.example.com');
        $record = row();

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('failed');
    });

    test('a record with the same name in another zone is no conflict', function (): void {
        $this->cf->seed('A', 'kampung.mc.example.com', zone: FakeCloudflare::OTHER_ZONE);
        $record = row();

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('active');
    });
});

describe('changing the name (AC-S5, FR-S6, EC-S8)', function (): void {
    test('AC-S5 a new label: the old records go by id, the new ones are made', function (): void {
        $record = row();
        syncer()->sync($record);
        [$oldA, $oldSrv] = [$record->refresh()->a_record_id, $record->srv_record_id];
        $record->update(['label' => 'baru', 'status' => 'pending']);

        syncer()->sync($record);

        expect($this->cf->named('A', 'kampung.mc.example.com'))->toBe([])
            ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toBe([])
            ->and($this->cf->named('A', 'baru.mc.example.com'))->toHaveCount(1)
            ->and($this->cf->named('SRV', '_minecraft._tcp.baru.mc.example.com'))->toHaveCount(1);
        expect($this->cf->trace())->toContain("DELETE $oldA")->toContain("DELETE $oldSrv");
        $record->refresh();
        expect($record->status)->toBe('active')->and($record->synced_name)->toBe('baru.mc.example.com')
            ->and($record->a_record_id)->not->toBe($oldA);
    });

    test('NFR-S5 the old records are removed by id: a stranger with the old name is not deleted', function (): void {
        $record = row();
        syncer()->sync($record);
        $stranger = $this->cf->seed('A', 'kampung.mc.example.com'); // someone adds a second A record under the old name
        $record->update(['label' => 'baru', 'status' => 'pending']);

        syncer()->sync($record);

        expect(array_column($this->cf->named('A', 'kampung.mc.example.com'), 'id'))->toBe([$stranger]);
    });

    test('a new domain in another zone: records are removed from the zone they were made in, then made in the new one', function (): void {
        $record = row();
        syncer()->sync($record);
        $record->update(['domain' => 'play.example.org', 'status' => 'pending']);

        syncer()->sync($record);

        expect($this->cf->named('A', 'kampung.mc.example.com', ZONE))->toBe([])
            ->and($this->cf->named('A', 'kampung.play.example.org', FakeCloudflare::OTHER_ZONE))->toHaveCount(1);
        expect($record->refresh()->zone_id)->toBe(FakeCloudflare::OTHER_ZONE);
    });

    test('a failure while removing the old records keeps what is left, and the retry finishes the job', function (): void {
        $record = row();
        syncer()->sync($record);
        $record->update(['label' => 'baru', 'status' => 'pending']);
        $this->cf->failNext('DELETE', 503); // the first delete (the SRV record) fails

        expect(fn () => syncer()->sync($record))->toThrow(CloudflareException::class);
        $record->refresh();
        expect($record->srv_record_id)->not->toBeNull()->and($record->a_record_id)->not->toBeNull()->and($record->synced_name)->toBe('kampung.mc.example.com');

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('active')->and($this->cf->all())->toHaveCount(2);
    });
});

describe('removing (AC-S6, AC-S7, AC-S8, EC-S4, EC-S5, EC-S8, Fokus-4)', function (): void {
    test('AC-S7 a deleting row: SRV then A are deleted by id, then the row is gone', function (): void {
        $record = row();
        syncer()->sync($record);
        [$a, $srv] = [$record->refresh()->a_record_id, $record->srv_record_id];
        $record->update(['status' => 'deleting']);
        $this->cf->calls = [];

        syncer()->sync($record);

        expect($this->cf->trace())->toBe(["DELETE $srv", "DELETE $a"])
            ->and($this->cf->all())->toBe([])
            ->and(Record::query()->whereKey($record->id)->exists())->toBeFalse();
    });

    test('EC-S4 records already removed by hand count as removed (404)', function (): void {
        $record = row();
        syncer()->sync($record);
        $this->cf->zones[ZONE] = [];
        $record->update(['status' => 'deleting']);

        syncer()->sync($record);

        expect(Record::query()->whereKey($record->id)->exists())->toBeFalse();
    });

    test('EC-S5 Fokus-4 a row that never reached Cloudflare is just deleted: no Cloudflare call, not even without a token', function (bool $withToken): void {
        $record = row(['status' => 'deleting']);

        syncer([], $withToken)->sync($record);

        expect($this->cf->calls)->toBe([])->and(Record::query()->whereKey($record->id)->exists())->toBeFalse();
    })->with([true, false]);

    test('AC-S8 Cloudflare down while deleting: the row stays deleting with the error, and a later run finishes', function (): void {
        $record = row();
        syncer()->sync($record);
        $record->update(['status' => 'deleting']);
        $this->cf->failNext('DELETE', 503);

        expect(fn () => syncer()->sync($record))->toThrow(CloudflareException::class);
        expect($record->refresh()->status)->toBe('deleting')->and($record->last_error)->toBe('1000: boom');

        syncer()->sync($record);

        expect(Record::query()->whereKey($record->id)->exists())->toBeFalse()->and($this->cf->all())->toBe([]);
    });

    test('a refusal while deleting (token revoked) does not mark the row failed: it stays deleting', function (): void {
        $record = row();
        syncer()->sync($record);
        $record->update(['status' => 'deleting']);
        $this->cf->failNext('DELETE', 403, null, 10000, 'Authentication error');

        syncer()->sync($record); // not retryable: recorded, not thrown

        expect($record->refresh()->status)->toBe('deleting')->and($record->last_error)->toBe('10000: Authentication error');
    });

    test('deleting without a token keeps the row and says why', function (): void {
        $record = row();
        syncer()->sync($record);
        $record->update(['status' => 'deleting']);
        $calls = count($this->cf->calls);

        syncer([], false)->sync($record);

        expect($record->refresh()->status)->toBe('deleting')->and($record->last_error)->toStartWith('config:')
            ->and(count($this->cf->calls))->toBe($calls);
    });

    test('EC-S8 the domain left the list: the records are still removed, using the zone stored in the row', function (): void {
        $record = row();
        syncer()->sync($record);
        $record->update(['status' => 'deleting']);

        syncer(['domains' => []])->sync($record);

        expect($this->cf->all())->toBe([])->and(Record::query()->whereKey($record->id)->exists())->toBeFalse();
    });
});

describe('failures that are not worth retrying (AC-S15, EC-S6, EC-S7)', function (): void {
    test('AC-S15 a rejected token: failed, with the Cloudflare error and without the token', function (): void {
        $record = row();
        $this->cf->failNext('GET', 403, 'A', 10000, 'Authentication error');

        syncer()->sync($record);

        $record->refresh();
        expect($record->status)->toBe('failed')
            ->and($record->last_error)->toBe('10000: Authentication error')
            ->and($record->last_error)->not->toContain('cf-test-token');
    });

    test('EC-S7 a token without DNS edit permission: failed, the Cloudflare code is visible to the admin', function (): void {
        $record = row();
        $this->cf->failNext('POST', 403, 'A', 9109, 'Unauthorized to access requested resource');

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('failed')->and($record->last_error)->toBe('9109: Unauthorized to access requested resource');
    });

    test('EC-S6 an address that is missing or not IPv4: failed (config), nothing sent', function (string $ip): void {
        $record = row();

        syncer(['ip' => $ip])->sync($record);

        expect($record->refresh()->status)->toBe('failed')->and($record->last_error)->toStartWith('config:')
            ->and($this->cf->calls)->toBe([]);
    })->with(['', 'not an ip', '2001:db8::1', '999.1.1.1', '203.0.113.10/32', ' ']);

    test('no token: failed (config), nothing sent', function (): void {
        $record = row();

        syncer([], false)->sync($record);

        expect($record->refresh()->status)->toBe('failed')->and($record->last_error)->toBe('config: the Cloudflare token is not set')
            ->and($this->cf->calls)->toBe([]);
    });

    test('a domain that is not in the list: failed (config), nothing sent', function (): void {
        $record = row(['domain' => 'unknown.example.net']);

        syncer()->sync($record);

        expect($record->refresh()->status)->toBe('failed')->and($record->last_error)->toContain('not in the configured domain list')
            ->and($this->cf->calls)->toBe([]);
    });

    test('an invalid TTL is refused before anything is sent', function (int $ttl): void {
        $record = row();

        syncer(['ttl' => $ttl])->sync($record);

        expect($record->refresh()->status)->toBe('failed')->and($this->cf->calls)->toBe([]);
    })->with([0, 2, 59, 86401, -1]);

    test('a TTL of 1 (automatic) and the bounds are accepted', function (int $ttl): void {
        $record = row();

        syncer(['ttl' => $ttl])->sync($record);

        expect($record->refresh()->status)->toBe('active');
    })->with([1, 60, 86400]);

    test('the error text on the row never exceeds the column', function (): void {
        $record = row();
        $this->cf->failNext('GET', 400, 'A', 1004, str_repeat('very long ', 100));

        syncer()->sync($record);

        expect(strlen($record->refresh()->last_error))->toBeLessThanOrEqual(200);
    });
});

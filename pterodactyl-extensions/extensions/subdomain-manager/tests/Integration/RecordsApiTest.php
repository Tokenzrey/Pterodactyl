<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Str;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// The admin overview page: setup checklist, connection test, record list, retry and remove.

const BASE = '/api/admin/extensions/subdomain-manager';

function makeRow(array $override = []): Record
{
    return Record::query()->create($override + [
        'server_id' => null, 'server_uuid' => (string) Str::uuid(), 'domain' => 'mc.example.com',
        'label' => 'k'.Str::lower(Str::random(8)), 'zone_id' => FakeCloudflare::ZONE, 'status' => Record::ACTIVE,
    ]);
}

beforeEach(function (): void {
    $this->configureCloudflare();
    $this->cf = (new FakeCloudflare)->install();
});

describe('access', function (): void {
    test('guests and ordinary users are refused on every new endpoint', function (string $method, string $path): void {
        $row = makeRow();
        $url = str_replace('{id}', (string) $row->id, BASE.$path);

        $this->json($method, $url)->assertUnauthorized();
        $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => false]));
        $this->json($method, $url)->assertForbidden();

        expect($this->cf->calls)->toBe([]);
        expect(Record::query()->whereKey($row->id)->value('status'))->toBe('active');
    })->with([['GET', '/overview'], ['POST', '/test'], ['GET', '/records'], ['POST', '/records/{id}/retry'], ['DELETE', '/records/{id}']]);
});

describe('overview', function (): void {
    beforeEach(fn () => $this->actingAsAdmin());

    test('a configured install is ready and counts the rows by status', function (): void {
        makeRow();
        makeRow();
        makeRow(['status' => 'failed']);
        makeRow(['status' => 'pending']);

        $this->getJson(BASE.'/overview')->assertOk()->assertExactJson([
            'setup' => ['token' => true, 'domains' => 1, 'target_ip' => true, 'srv_enabled' => true],
            'counts' => ['active' => 2, 'pending' => 1, 'failed' => 1, 'deleting' => 0, 'total' => 4],
        ]);
    });

    test('a fresh install shows what is missing, without ever revealing the values', function (): void {
        $this->app->make(Pterodactyl\Services\Extensions\ExtensionRepository::class)->settings('subdomain-manager')->setSecret('cloudflare_token', '');
        $this->configure(['domains' => []]);
        $this->app->make(Pterodactyl\Services\Extensions\ExtensionRepository::class)->settings('subdomain-manager')->set('target_ipv4', '');

        $response = $this->getJson(BASE.'/overview')->assertOk();

        expect($response->json('setup'))->toBe(['token' => false, 'domains' => 0, 'target_ip' => false, 'srv_enabled' => true]);
        expect($response->getContent())->not->toContain(self::TOKEN)->not->toContain(FakeCloudflare::ZONE);
    });
});

describe('connection test', function (): void {
    beforeEach(fn () => $this->actingAsAdmin());

    test('it checks every configured domain against Cloudflare and reports each', function (): void {
        $this->configure(['domains' => ['mc.example.com:'.FakeCloudflare::ZONE, 'play.example.org:'.FakeCloudflare::OTHER_ZONE]]);
        $this->cf->failNext('GET', 403, null, 10000, 'Authentication error');

        $response = $this->postJson(BASE.'/test')->assertOk();

        expect($response->json())->toBe(['problem' => null, 'results' => [
            ['domain' => 'mc.example.com', 'ok' => false, 'message' => '10000: Authentication error'],
            ['domain' => 'play.example.org', 'ok' => true, 'message' => null],
        ]]);
        expect($response->getContent())->not->toContain(self::TOKEN)->not->toContain(FakeCloudflare::ZONE);
    });

    test('with no token or no domain it says which, and calls nothing', function (string $what): void {
        if ($what === 'token') {
            $this->app->make(Pterodactyl\Services\Extensions\ExtensionRepository::class)->settings('subdomain-manager')->setSecret('cloudflare_token', '');
        } else {
            $this->configure(['domains' => []]);
        }

        $this->postJson(BASE.'/test')->assertOk()->assertExactJson(['problem' => $what, 'results' => []]);

        expect($this->cf->calls)->toBe([]);
    })->with(['token', 'domains']);

    test('Cloudflare being unreachable is a failed result, not a server error', function (): void {
        $this->cf->failNext('GET', 503);

        $this->postJson(BASE.'/test')->assertOk()->assertJsonPath('results.0.ok', false);
    });
});

describe('record list', function (): void {
    beforeEach(fn () => $this->actingAsAdmin());

    test('it lists rows newest first with the address, status, error and server', function (): void {
        $server = $this->createServerModel(['name' => 'Survival']);
        $old = makeRow(['label' => 'old', 'updated_at' => now()->subHour()]);
        makeRow(['label' => 'mine', 'server_id' => $server->id, 'server_uuid' => $server->uuid, 'status' => 'failed', 'last_error' => 'conflict: …']);
        Record::query()->whereKey($old->id)->update(['updated_at' => now()->subHour()]);

        $response = $this->getJson(BASE.'/records')->assertOk();

        expect(array_column($response->json('data'), 'address'))->toBe(['mine.mc.example.com', 'old.mc.example.com']);
        expect($response->json('data.0'))->toMatchArray(['label' => 'mine', 'domain' => 'mc.example.com', 'status' => 'failed', 'last_error' => 'conflict: …', 'server' => ['id' => $server->id, 'name' => 'Survival']]);
        expect($response->json('data.1.server'))->toBeNull();
        expect($response->json('meta'))->toMatchArray(['page' => 1, 'pages' => 1, 'total' => 2]);
    });

    test('it never exposes record ids at Cloudflare, zone ids or the token', function (): void {
        makeRow(['a_record_id' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'srv_record_id' => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb']);

        $body = $this->getJson(BASE.'/records')->assertOk()->getContent();

        expect($body)->not->toContain('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')->not->toContain('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
            ->not->toContain(FakeCloudflare::ZONE)->not->toContain(self::TOKEN);
    });

    test('it filters by status and by a search over the address', function (): void {
        makeRow(['label' => 'alpha']);
        makeRow(['label' => 'bravo', 'status' => 'failed']);
        makeRow(['label' => 'alphabet', 'status' => 'failed']);

        expect(array_column($this->getJson(BASE.'/records?status=failed')->json('data'), 'label'))->toEqualCanonicalizing(['bravo', 'alphabet']);
        expect(array_column($this->getJson(BASE.'/records?q=alpha')->json('data'), 'label'))->toEqualCanonicalizing(['alpha', 'alphabet']);
        expect(array_column($this->getJson(BASE.'/records?q=alpha&status=failed')->json('data'), 'label'))->toBe(['alphabet']);
    });

    test('search wildcards are literal characters', function (): void {
        makeRow(['label' => 'alpha']);

        expect($this->getJson(BASE.'/records?q=%25')->json('data'))->toBe([])
            ->and($this->getJson(BASE.'/records?q=_lpha')->json('data'))->toBe([]);
    });

    test('it pages 25 at a time', function (): void {
        foreach (range(1, 27) as $i) {
            makeRow(['label' => "row$i"]);
        }

        $first = $this->getJson(BASE.'/records')->json();
        $second = $this->getJson(BASE.'/records?page=2')->json();

        expect($first['data'])->toHaveCount(25)->and($second['data'])->toHaveCount(2)->and($first['meta'])->toMatchArray(['page' => 1, 'pages' => 2, 'total' => 27]);
    });

    test('bad filters are a 422', function (string $query): void {
        $this->getJson(BASE.'/records?'.$query)->assertUnprocessable();
    })->with(['status=bogus', 'page=0', 'page=abc', 'q[]=a', 'status[]=failed']);
});

describe('retry and remove', function (): void {
    beforeEach(fn () => $this->actingAsAdmin());

    test('retry queues a failed row again as pending', function (): void {
        Bus::fake([SyncRecord::class]);
        $row = makeRow(['status' => 'failed', 'last_error' => 'conflict: …', 'attempts' => 3]);

        $this->postJson(BASE."/records/{$row->id}/retry")->assertStatus(202)->assertJsonPath('status', 'pending');

        $row->refresh();
        expect($row->status)->toBe('pending')->and($row->last_error)->toBeNull()->and($row->attempts)->toBe(0);
        Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $row->id);
    });

    test('retry with the queue running heals a row whose cause is gone', function (): void {
        $row = makeRow(['status' => 'failed', 'label' => 'kampung']);

        $this->postJson(BASE."/records/{$row->id}/retry")->assertStatus(202);

        expect($row->refresh()->status)->toBe('active')->and($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1);
    });

    test('a row being removed is just queued again, and an active row is refused', function (): void {
        Bus::fake([SyncRecord::class]);
        $deleting = makeRow(['status' => 'deleting']);
        $active = makeRow(['status' => 'active']);

        $this->postJson(BASE."/records/{$deleting->id}/retry")->assertStatus(202)->assertJsonPath('status', 'deleting');
        $this->postJson(BASE."/records/{$active->id}/retry")->assertStatus(409);

        Bus::assertDispatchedTimes(SyncRecord::class, 1);
        expect($active->refresh()->status)->toBe('active');
    });

    test('remove marks the row deleting and queues the cleanup', function (): void {
        Bus::fake([SyncRecord::class]);
        $row = makeRow(['status' => 'active']);

        $this->deleteJson(BASE."/records/{$row->id}")->assertStatus(202)->assertJsonPath('status', 'deleting');

        expect($row->refresh()->status)->toBe('deleting');
        Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $row->id);
    });

    test('remove with the queue running deletes the records at Cloudflare, by id, and the row', function (): void {
        $row = makeRow(['label' => 'kampung', 'status' => 'pending']);
        SyncRecord::dispatchSync($row->id);
        $stranger = $this->cf->seed('A', 'kampung.mc.example.com');

        $this->deleteJson(BASE."/records/{$row->id}")->assertStatus(202);

        expect(Record::query()->whereKey($row->id)->exists())->toBeFalse()
            ->and(array_column($this->cf->named('A', 'kampung.mc.example.com'), 'id'))->toBe([$stranger]);
    });

    test('an unknown row is a 404', function (): void {
        $this->postJson(BASE.'/records/999999/retry')->assertNotFound();
        $this->deleteJson(BASE.'/records/999999')->assertNotFound();
    });

    test('a row id that is not a number never reaches the database', function (): void {
        $this->postJson(BASE.'/records/abc/retry')->assertNotFound();
    });
});

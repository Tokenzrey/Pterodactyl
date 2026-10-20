<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\Location;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Tests\Support\Fakes\FakeDaemonServer;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-S1 to FR-S3, FR-S7, FR-S13, AC-S1, AC-S5 to AC-S13, EC-S1: the real admin API end to end (the Panel's own
// routes, validation and transaction), with Cloudflare and Wings faked. The queue is `sync`, so a job that is not
// faked by Bus::fake() runs inline right after the commit and the DNS state can be asserted at the end of a request.

beforeEach(function (): void {
    $this->actingAsAdmin();
    $this->configureCloudflare();
    $this->daemon = new FakeDaemonServer; // before the Cloudflare fake: both are added to the same HTTP client
    $this->cf = (new FakeCloudflare)->install(fresh: false);
});

function fieldsOf(Server $server): array
{
    return test()->getJson(route('api.admin.servers.view', ['server' => $server->id]))->assertOk()->json('attributes.extensions.subdomain-manager');
}

describe('saving (AC-S1, FR-S3)', function (): void {
    test('AC-S1 a label and domain make a pending row, queue the job after the commit, and call Cloudflare zero times in the request', function (): void {
        Bus::fake([SyncRecord::class]);
        $server = $this->createServerModel();

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk()
            ->assertJsonPath('attributes.extensions.subdomain-manager.label', 'kampung')
            ->assertJsonPath('attributes.extensions.subdomain-manager.domain', 'mc.example.com')
            ->assertJsonPath('attributes.extensions.subdomain-manager.status', 'pending')
            ->assertJsonPath('attributes.extensions.subdomain-manager.fqdn', 'kampung.mc.example.com');

        $record = Record::query()->where('server_uuid', $server->uuid)->sole();
        expect($record->status)->toBe('pending')
            ->and($record->server_id)->toBe($server->id)
            ->and($record->zone_id)->toBe(FakeCloudflare::ZONE)
            ->and($record->a_record_id)->toBeNull();
        Bus::assertDispatchedTimes(SyncRecord::class, 1);
        Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $record->id);
        expect($this->cf->calls)->toBe([]);
    });

    test('FR-S3 the job is queued only once the surrounding transaction commits, and never if it rolls back', function (): void {
        Bus::fake([SyncRecord::class]);
        $server = $this->createServerModel();
        $values = ['label' => 'kampung', 'domain' => 'mc.example.com'];
        $save = fn () => app()->call([new SubdomainManager\Fields\SubdomainFields, 'save'], ['server' => $server, 'values' => $values]);

        // Rolled back: nothing may be queued for a row that does not exist.
        try {
            DB::transaction(function () use ($save): void {
                $save();
                Bus::assertNothingDispatched();
                throw new RuntimeException('the server save failed after our fields were written');
            });
        } catch (RuntimeException) {
        }
        Bus::assertNothingDispatched();
        expect(Record::query()->count())->toBe(0);

        // Committed: queued when the transaction ends, not before.
        DB::transaction(function () use ($save): void {
            $save();
            Bus::assertNothingDispatched();
        });
        Bus::assertDispatchedTimes(SyncRecord::class, 1);
    });

    test('AC-S2 with the queue running, one save leaves an active row and both DNS records', function (): void {
        $server = $this->createServerModel();

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        $record = Record::query()->where('server_uuid', $server->uuid)->sole();
        expect($record->status)->toBe('active')
            ->and($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1)
            ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toHaveCount(1);
        expect(fieldsOf($server))->toMatchArray(['label' => 'kampung', 'domain' => 'mc.example.com', 'status' => 'active', 'fqdn' => 'kampung.mc.example.com', 'error' => null]);
    });

    test('creating a server with a subdomain links the row to the new server and takes the SRV port from its allocation', function (): void {
        $this->configure(['srv_port' => 0]);
        $node = Node::factory()->for(Location::factory())->create();
        $allocation = Allocation::factory()->create(['node_id' => $node->id]);

        $response = $this->postJson(route('api.admin.servers.store'), [
            'name' => 'Created With Subdomain', 'owner_id' => User::factory()->create()->id,
            'egg_id' => Egg::query()->where('author', 'support@pterodactyl.io')->where('name', 'Bungeecord')->firstOrFail()->id,
            'docker_image' => 'ghcr.io/pterodactyl/yolks:java_21', 'startup' => 'java -jar server.jar',
            'environment' => ['BUNGEE_VERSION' => '123', 'SERVER_JARFILE' => 'server.jar'],
            'memory' => 512, 'swap' => 0, 'disk' => 1024, 'io' => 500, 'cpu' => 0, 'database_limit' => 0, 'allocation_limit' => 0, 'backup_limit' => 0,
            'primary_allocation_id' => $allocation->id,
            'extensions' => ['subdomain-manager' => ['label' => 'newbie', 'domain' => 'mc.example.com']],
        ])->assertCreated();

        $server = Server::query()->findOrFail($response->json('attributes.id'));
        $record = Record::query()->where('server_uuid', $server->uuid)->sole();
        expect($record->server_id)->toBe($server->id)->and($record->status)->toBe('active');
        expect($this->cf->named('SRV', '_minecraft._tcp.newbie.mc.example.com')[0]['data']['port'])->toBe($allocation->port);
    });

    test('saving the same active name again does nothing (no job, no Cloudflare call)', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        $before = count($this->cf->calls);
        Bus::fake([SyncRecord::class]);

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        Bus::assertNotDispatched(SyncRecord::class);
        expect(count($this->cf->calls))->toBe($before);
    });

    test('saving a failed name again retries it', function (): void {
        $this->cf->seed('A', 'kampung.mc.example.com'); // somebody else holds the name
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        expect(Record::query()->where('server_uuid', $server->uuid)->sole()->status)->toBe('failed');
        $this->cf->zones[FakeCloudflare::ZONE] = []; // the stranger leaves

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        expect(Record::query()->where('server_uuid', $server->uuid)->sole()->status)->toBe('active');
    });

    test('a form without the extension values leaves the subdomain as it is', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        $this->putJson(route('api.admin.servers.details', ['server' => $server->id]), ['name' => 'Renamed', 'owner_id' => $server->owner_id])->assertOk();

        expect(Record::query()->where('server_uuid', $server->uuid)->sole()->label)->toBe('kampung');
    });
});

describe('validation (AC-S9, AC-S10, AC-S11, EC-S1)', function (): void {
    test('AC-S9 a label that breaks the rules is a 422 on the label field, and nothing is stored or queued', function (string $label): void {
        Bus::fake([SyncRecord::class]);
        $server = $this->createServerModel();

        $response = $this->saveSubdomain($server, ['label' => $label, 'domain' => 'mc.example.com'])->assertUnprocessable();

        expect(collect($response->json('errors'))->pluck('meta.source_field')->all())->toContain('extensions.subdomain-manager.label');
        expect(Record::query()->count())->toBe(0);
        Bus::assertNothingDispatched();
    })->with([
        'reserved' => ['www'],
        'reserved admin' => ['admin'],
        'upper case' => ['Kampung'],
        'underscore' => ['a_b'],
        'dot' => ['a.b'],
        'leading hyphen' => ['-a'],
        'trailing hyphen' => ['a-'],
        '64 characters' => [str_repeat('a', 64)],
        'space' => ['a b'],
        'unicode' => ['kämpung'],
        'wildcard' => ['*'],
    ]);

    test('AC-S9 an administrator-defined reserved label is refused too, in any letter case', function (): void {
        $this->configure(['reserved_labels' => ['Staff', 'vip']]);
        $server = $this->createServerModel();

        $this->saveSubdomain($server, ['label' => 'staff', 'domain' => 'mc.example.com'])->assertUnprocessable();
        $this->saveSubdomain($server, ['label' => 'vip', 'domain' => 'mc.example.com'])->assertUnprocessable();
        $this->saveSubdomain($server, ['label' => 'www', 'domain' => 'mc.example.com'])->assertOk(); // no longer reserved: the list was replaced
    });

    test('AC-S10 a name another server holds is refused; the server holding it can keep it', function (): void {
        $first = $this->createServerModel();
        $second = $this->createServerModel();
        $this->saveSubdomain($first, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        $response = $this->saveSubdomain($second, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertUnprocessable();

        expect(collect($response->json('errors'))->pluck('meta.source_field')->all())->toContain('extensions.subdomain-manager.label');
        $this->saveSubdomain($first, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        expect(Record::query()->count())->toBe(1);
    });

    test('AC-S10 the same label under another configured domain is a different name', function (): void {
        $this->configure(['domains' => ['mc.example.com:'.FakeCloudflare::ZONE, 'play.example.org:'.FakeCloudflare::OTHER_ZONE]]);
        $first = $this->createServerModel();
        $second = $this->createServerModel();
        $this->saveSubdomain($first, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        $this->saveSubdomain($second, ['label' => 'kampung', 'domain' => 'play.example.org'])->assertOk();

        expect($this->cf->named('A', 'kampung.play.example.org', FakeCloudflare::OTHER_ZONE))->toHaveCount(1);
    });

    test('AC-S10 a name still being cleaned up after its server was deleted cannot be reused yet', function (): void {
        $dead = Record::query()->create(['server_id' => null, 'server_uuid' => (string) Str::uuid(), 'domain' => 'mc.example.com', 'label' => 'kampung', 'zone_id' => FakeCloudflare::ZONE, 'status' => 'deleting']);
        $server = $this->createServerModel();

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertUnprocessable();

        expect(Record::query()->whereKey($dead->id)->exists())->toBeTrue();
    });

    test('AC-S11 a domain that is not configured is a 422 on the domain field', function (string $domain): void {
        $server = $this->createServerModel();

        $response = $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => $domain])->assertUnprocessable();

        expect(collect($response->json('errors'))->pluck('meta.source_field')->all())->toContain('extensions.subdomain-manager.domain');
        expect(Record::query()->count())->toBe(0);
    })->with(['evil.example.net', 'example.com', 'MC.EXAMPLE.COM.evil.net', '../x']);

    test('a label without a domain is a 422 on the domain field', function (): void {
        $server = $this->createServerModel();

        $response = $this->saveSubdomain($server, ['label' => 'kampung'])->assertUnprocessable();

        expect(collect($response->json('errors'))->pluck('meta.source_field')->all())->toContain('extensions.subdomain-manager.domain');
    });

    test('values of the wrong type are refused, not coerced', function (array $payload): void {
        $server = $this->createServerModel();

        $this->saveSubdomain($server, $payload)->assertUnprocessable();

        expect(Record::query()->count())->toBe(0);
    })->with([
        'label is a number' => [['label' => 123, 'domain' => 'mc.example.com']],
        'label is a list' => [['label' => ['a'], 'domain' => 'mc.example.com']],
        'domain is a list' => [['label' => 'kampung', 'domain' => ['mc.example.com']]],
        'label is true' => [['label' => true, 'domain' => 'mc.example.com']],
    ]);

    test('EC-S1 two administrators taking the same name at once: the loser gets a 422 and the whole save rolls back', function (): void {
        $server = $this->createServerModel();
        $armed = true;
        Record::creating(function () use (&$armed): void {
            if ($armed) {
                $armed = false;
                // The other administrator's save commits between our validation and our write.
                DB::table('ext_subdomain_manager_records')->insert(['server_id' => null, 'server_uuid' => (string) Str::uuid(), 'domain' => 'mc.example.com', 'label' => 'kampung', 'zone_id' => FakeCloudflare::ZONE, 'status' => 'pending', 'created_at' => now(), 'updated_at' => now()]);
            }
        });

        $response = $this->putJson(route('api.admin.servers.details', ['server' => $server->id]), ['name' => 'Should Not Stick', 'owner_id' => $server->owner_id, 'extensions' => ['subdomain-manager' => ['label' => 'kampung', 'domain' => 'mc.example.com']]]);

        $response->assertUnprocessable();
        expect(collect($response->json('errors'))->pluck('meta.source_field')->all())->toContain('extensions.subdomain-manager.label');
        expect($server->refresh()->name)->not->toBe('Should Not Stick')
            ->and(Record::query()->where('server_uuid', $server->uuid)->exists())->toBeFalse();
    });
});

describe('changing and removing (AC-S5, AC-S6)', function (): void {
    test('AC-S5 a new label replaces the old records, by id', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        $stranger = $this->cf->seed('A', 'kampung.mc.example.com'); // a later, unrelated record under the old name

        $this->saveSubdomain($server, ['label' => 'baru', 'domain' => 'mc.example.com'])->assertOk();

        expect(array_column($this->cf->named('A', 'kampung.mc.example.com'), 'id'))->toBe([$stranger])
            ->and($this->cf->named('A', 'baru.mc.example.com'))->toHaveCount(1)
            ->and($this->cf->named('SRV', '_minecraft._tcp.kampung.mc.example.com'))->toBe([])
            ->and($this->cf->named('SRV', '_minecraft._tcp.baru.mc.example.com'))->toHaveCount(1);
        expect(Record::query()->where('server_uuid', $server->uuid)->sole())->label->toBe('baru')->status->toBe('active');
    });

    test('AC-S6 an empty label removes the records and the row', function (?string $label): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        $this->saveSubdomain($server, ['label' => $label, 'domain' => ''])->assertOk()
            ->assertJsonPath('attributes.extensions.subdomain-manager.label', '');

        expect($this->cf->all())->toBe([])->and(Record::query()->count())->toBe(0);
    })->with(['', null]);

    test('AC-S6 an empty label with the queue faked marks the row deleting and queues the job', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        Bus::fake([SyncRecord::class]);

        $this->saveSubdomain($server, ['label' => '', 'domain' => ''])->assertOk();

        expect(Record::query()->where('server_uuid', $server->uuid)->sole()->status)->toBe('deleting');
        Bus::assertDispatchedTimes(SyncRecord::class, 1);
    });

    test('an empty label on a server that never had a subdomain is a no-op', function (): void {
        Bus::fake([SyncRecord::class]);
        $server = $this->createServerModel();

        $this->saveSubdomain($server, ['label' => '', 'domain' => ''])->assertOk();

        Bus::assertNothingDispatched();
        expect(Record::query()->count())->toBe(0);
    });

    test('FR-S3 FR-S13 Cloudflare being down while saving does not fail the save', function (): void {
        $this->cf->failNext('GET', 503, 'A');
        $server = $this->createServerModel();

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        // The test queue is `sync`: no retries, so the first failure is final. On a real queue the row would stay
        // pending between retries; either way the save itself succeeded and reconcile retries later.
        $record = Record::query()->where('server_uuid', $server->uuid)->sole();
        expect($record->status)->toBe('failed')->and($record->last_error)->toBe('1000: boom');
    });
});

describe('deleting the server (AC-S7, AC-S8, FR-S13)', function (): void {
    test('AC-S7 deleting a server removes its DNS records and its row', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        expect($this->cf->all())->toHaveCount(2);

        $this->delete(route('api.admin.servers.delete', ['server' => $server->id]))->assertNoContent();

        expect($this->cf->all())->toBe([])->and(Record::query()->count())->toBe(0);
    });

    test('AC-S7 with the queue faked: the row is marked deleting, detached from the gone server, and the job queued', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        Bus::fake([SyncRecord::class]);

        $this->delete(route('api.admin.servers.delete', ['server' => $server->id]))->assertNoContent();

        $record = Record::query()->sole();
        expect($record->status)->toBe('deleting')->and($record->server_id)->toBeNull()->and($record->a_record_id)->not->toBeNull();
        Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $record->id);
    });

    test('AC-S8 FR-S13 Cloudflare down: the server is still deleted, the row waits as deleting, and reconcile finishes the job later', function (): void {
        $server = $this->createServerModel();
        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();
        $this->cf->failNext('DELETE', 503);

        $this->delete(route('api.admin.servers.delete', ['server' => $server->id]))->assertNoContent();

        $this->assertDatabaseMissing('servers', ['id' => $server->id]);
        $record = Record::query()->sole();
        expect($record->status)->toBe('deleting')->and($record->last_error)->toBe('1000: boom');
        expect($this->cf->all())->not->toBe([]);

        $this->travel(6)->minutes();
        $this->artisan('subdomain-manager:reconcile')->assertSuccessful();

        expect($this->cf->all())->toBe([])->and(Record::query()->count())->toBe(0);
    });

    test('deleting a server that has no subdomain touches nothing', function (): void {
        $server = $this->createServerModel();

        $this->delete(route('api.admin.servers.delete', ['server' => $server->id]))->assertNoContent();

        expect($this->cf->calls)->toBe([])->and(Record::query()->count())->toBe(0);
    });

    test('only the deleted server\'s own row is touched', function (): void {
        $gone = $this->createServerModel();
        $stays = $this->createServerModel();
        $this->saveSubdomain($gone, ['label' => 'one', 'domain' => 'mc.example.com'])->assertOk();
        $this->saveSubdomain($stays, ['label' => 'two', 'domain' => 'mc.example.com'])->assertOk();

        $this->delete(route('api.admin.servers.delete', ['server' => $gone->id]))->assertNoContent();

        expect(Record::query()->pluck('label')->all())->toBe(['two'])
            ->and($this->cf->named('A', 'two.mc.example.com'))->toHaveCount(1);
    });
});

describe('access and exposure (AC-S12, AC-S13, FR-S12)', function (): void {
    test('AC-S12 a non-administrator cannot send or read subdomain values', function (): void {
        $server = $this->createServerModel();
        $this->actingAs(User::factory()->create(['root_admin' => false]));

        $this->putJson(route('api.admin.servers.details', ['server' => $server->id]), $this->detailsPayload($server, ['label' => 'kampung', 'domain' => 'mc.example.com']))->assertForbidden();
        $this->getJson(route('api.admin.servers.view', ['server' => $server->id]))->assertForbidden();
        expect(Record::query()->count())->toBe(0);
    });

    test('the admin forms list the extension on the server form for administrators', function (): void {
        $forms = $this->getJson(route('api.admin.extensions.forms'))->assertOk()->json('data');

        expect($forms['admin.server'][0]['id'])->toBe('subdomain-manager');
    });

    test('AC-S13 FR-S12 no response of the server form API carries the token or a zone id', function (): void {
        $server = $this->createServerModel();

        $bodies = [
            $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk()->getContent(),
            $this->getJson(route('api.admin.servers.view', ['server' => $server->id]))->getContent(),
            $this->getJson(route('api.admin.extensions.forms'))->getContent(),
        ];

        foreach ($bodies as $body) {
            expect($body)->not->toContain(self::TOKEN)->not->toContain(FakeCloudflare::ZONE)->not->toContain(FakeCloudflare::OTHER_ZONE);
        }
    });

    test('FR-S12 the settings form shows the token only as a mask (the domain:zone list is what the administrator typed)', function (): void {
        $body = $this->getJson(route('api.admin.extensions.settings', ['extension' => 'subdomain-manager']))->assertOk()->getContent();

        expect($body)->not->toContain(self::TOKEN)->toContain('********');
    });

    test('FR-S12 the token is in no log line, whatever fails', function (): void {
        config(['logging.default' => 'sdm_capture', 'logging.channels.sdm_capture' => ['driver' => 'monolog', 'handler' => Monolog\Handler\TestHandler::class, 'level' => 'debug']]);
        $server = $this->createServerModel();
        $this->cf->failNext('GET', 403, 'A', 6003, 'Invalid request headers: Bearer '.self::TOKEN);

        $this->saveSubdomain($server, ['label' => 'kampung', 'domain' => 'mc.example.com'])->assertOk();

        $log = collect(Log::channel('sdm_capture')->getLogger()->getHandlers()[0]->getRecords())->map(fn ($r) => $r->message.' '.json_encode($r->context))->implode("\n");
        expect($log)->not->toContain(self::TOKEN);
        expect(Record::query()->sole()->last_error)->not->toContain(self::TOKEN);
    });
});

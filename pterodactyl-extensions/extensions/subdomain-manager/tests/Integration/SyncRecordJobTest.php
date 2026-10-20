<?php

declare(strict_types=1);

use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-S8, FR-S9, AC-S16, EC-S9: the queue job, the reconcile command and its schedule.

function pendingRow(array $override = []): Record
{
    return Record::query()->create($override + [
        'server_id' => null, 'server_uuid' => (string) Str::uuid(), 'domain' => 'mc.example.com', 'label' => 'k'.Str::lower(Str::random(8)),
        'zone_id' => FakeCloudflare::ZONE, 'status' => Record::PENDING,
    ]);
}

beforeEach(function (): void {
    $this->configureCloudflare();
    $this->cf = (new FakeCloudflare)->install();
});

describe('the job', function (): void {
    test('it makes the records of its row using the stored settings', function (): void {
        $record = pendingRow(['label' => 'kampung']);

        SyncRecord::dispatchSync($record->id);

        expect($record->refresh()->status)->toBe('active')
            ->and($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1);
    });

    test('FR-S8 it tries 5 times with pauses of 10, 30, 60 and 120 seconds', function (): void {
        $job = new SyncRecord(1);

        expect($job->tries)->toBe(5)->and($job->backoff())->toBe([10, 30, 60, 120]);
    });

    test('EC-S9 FR-S4 it is unique per row: two jobs for one row share a lock, two rows do not', function (): void {
        expect((new SyncRecord(7))->uniqueId())->toBe((new SyncRecord(7))->uniqueId())
            ->and((new SyncRecord(7))->uniqueId())->not->toBe((new SyncRecord(8))->uniqueId())
            ->and(new SyncRecord(1))->toBeInstanceOf(Illuminate\Contracts\Queue\ShouldBeUnique::class)
            ->and(new SyncRecord(1))->toBeInstanceOf(Illuminate\Contracts\Queue\ShouldQueue::class);
    });

    test('only the row id travels in the payload, never a model or a secret', function (): void {
        $payload = serialize(new SyncRecord(42));

        expect($payload)->toContain('recordId')->not->toContain(self::TOKEN)->not->toContain('Models\Record')->not->toContain('ModelIdentifier');
    });

    test('a row deleted before the job runs is a quiet no-op', function (): void {
        SyncRecord::dispatchSync(999999);

        expect($this->cf->calls)->toBe([]);
    });

    test('no token: the row fails with a config message and Cloudflare is not called', function (): void {
        $this->app->make(Pterodactyl\Services\Extensions\ExtensionRepository::class)->settings('subdomain-manager')->setSecret('cloudflare_token', '');
        $record = pendingRow();

        SyncRecord::dispatchSync($record->id);

        expect($record->refresh()->status)->toBe('failed')->and($record->last_error)->toBe('config: the Cloudflare token is not set')
            ->and($this->cf->calls)->toBe([]);
    });

    test('FR-S8 after the last try the row is failed with a safe message', function (): void {
        $record = pendingRow();

        (new SyncRecord($record->id))->failed(new SubdomainManager\Support\CloudflareException(true, '1000: boom', 503));

        expect($record->refresh()->status)->toBe('failed')->and($record->last_error)->toBe('1000: boom');
    });

    test('an unexpected exception is shown as a generic message: its text may carry data', function (): void {
        $record = pendingRow();

        (new SyncRecord($record->id))->failed(new RuntimeException('SQLSTATE[23000] ... bindings: [secret@example.com, '.self::TOKEN.']'));

        expect($record->refresh()->last_error)->toBe('unexpected error while syncing; see the Panel log')
            ->and($record->last_error)->not->toContain(self::TOKEN);
    });

    test('a row being deleted stays deleting when its job gives up', function (): void {
        $record = pendingRow(['status' => 'deleting']);

        (new SyncRecord($record->id))->failed(new SubdomainManager\Support\CloudflareException(true, '1000: boom', 503));

        expect($record->refresh()->status)->toBe('deleting')->and($record->last_error)->toBe('1000: boom');
    });

    test('giving up is logged with the exception class only', function (): void {
        config(['logging.default' => 'sdm_capture', 'logging.channels.sdm_capture' => ['driver' => 'monolog', 'handler' => Monolog\Handler\TestHandler::class, 'level' => 'debug']]);
        $record = pendingRow();

        (new SyncRecord($record->id))->failed(new RuntimeException('secret detail '.self::TOKEN));

        $log = collect(Log::channel('sdm_capture')->getLogger()->getHandlers()[0]->getRecords())->map(fn ($r) => $r->message.' '.json_encode($r->context))->implode("\n");
        expect($log)->toContain('RuntimeException')->not->toContain('secret detail')->not->toContain(self::TOKEN);
    });

    test('dispatchSafely swallows a job that throws, so saving or deleting a server never fails on it', function (): void {
        $this->cf->failNext('GET', 503); // the job runs inline on the sync queue and throws
        $record = pendingRow();

        SyncRecord::dispatchSafely($record->id);

        expect($record->refresh()->status)->toBe('failed');
    });
});

describe('reconcile (AC-S16, FR-S9)', function (): void {
    function aged(Record $record, int $minutes): Record
    {
        Record::query()->whereKey($record->id)->update(['updated_at' => now()->subMinutes($minutes)]);

        return $record->refresh();
    }

    test('AC-S16 it queues pending, failed and deleting rows older than five minutes, and nothing else', function (): void {
        Bus::fake([SyncRecord::class]);
        $pending = aged(pendingRow(), 6);
        $failed = aged(pendingRow(['status' => 'failed']), 10);
        $deleting = aged(pendingRow(['status' => 'deleting']), 60);
        aged(pendingRow(['status' => 'active']), 600);
        aged(pendingRow(), 4);
        aged(pendingRow(['status' => 'failed']), 1);
        aged(pendingRow(['status' => 'deleting']), 2);

        $this->artisan('subdomain-manager:reconcile')->expectsOutput('Queued 3 sync job(s).')->assertSuccessful();

        Bus::assertDispatchedTimes(SyncRecord::class, 3);
        foreach ([$pending, $failed, $deleting] as $record) {
            Bus::assertDispatched(SyncRecord::class, fn (SyncRecord $job): bool => $job->recordId === $record->id);
        }
    });

    test('it does nothing when everything is settled', function (): void {
        Bus::fake([SyncRecord::class]);
        aged(pendingRow(['status' => 'active']), 600);

        $this->artisan('subdomain-manager:reconcile')->expectsOutput('Queued 0 sync job(s).')->assertSuccessful();

        Bus::assertNothingDispatched();
    });

    test('with the queue running, a failed row whose cause is gone is healed', function (): void {
        $record = aged(pendingRow(['label' => 'kampung', 'status' => 'failed', 'last_error' => 'conflict: …']), 6);

        $this->artisan('subdomain-manager:reconcile')->assertSuccessful();

        expect($record->refresh()->status)->toBe('active')->and($this->cf->named('A', 'kampung.mc.example.com'))->toHaveCount(1);
    });

    test('one row that cannot be synced does not stop the others', function (): void {
        $this->cf->failNext('GET', 503, 'A');
        $first = aged(pendingRow(['label' => 'first']), 6);
        $second = aged(pendingRow(['label' => 'second']), 6);

        $this->artisan('subdomain-manager:reconcile')->assertSuccessful();

        expect($first->refresh()->status)->toBe('failed')->and($second->refresh()->status)->toBe('active');
    });

    test('FR-S9 the command is registered with the Panel and scheduled every five minutes', function (): void {
        // The Panel's kernel hands its scheduler to the registry; do the same with a fresh one.
        $schedule = new Schedule;
        $this->app->make(Pterodactyl\Services\Extensions\ExtensionConsoleRegistry::class)->schedule($schedule);
        $events = collect($schedule->events())->filter(fn ($event): bool => str_contains((string) $event->command, 'subdomain-manager:reconcile'));

        expect($events)->toHaveCount(1)
            ->and($events->first()->expression)->toBe('*/5 * * * *')
            ->and($events->first()->withoutOverlapping)->toBeTrue();
    });
});

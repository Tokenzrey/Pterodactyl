<?php

declare(strict_types=1);

namespace SubdomainManager\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldBeUnique;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Http\Client\Factory;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\Log;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\CloudflareClient;
use SubdomainManager\Support\CloudflareException;
use SubdomainManager\Support\RecordSyncer;
use SubdomainManager\Support\SubdomainSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use Throwable;

/**
 * Makes or removes the Cloudflare records of one row, outside of any request. Up to 5 tries, pausing
 * 10, 30, 60 and 120 seconds (FR-S8); one at a time per row (FR-S4, EC-S9). Only the row id travels, and the
 * row is read again when the job runs, so a job never acts on stale data.
 */
class SyncRecord implements ShouldBeUnique, ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;

    public int $tries = 5;

    /** How long a queued job keeps its row's lock if it never runs. */
    public int $uniqueFor = 600;

    public function __construct(public readonly int $recordId) {}

    /**
     * Queues the job for a row. A queue that is down, or (on the `sync` queue driver) a Cloudflare outage, must not
     * break saving or deleting a server: the row keeps its status and the reconcile command picks it up later.
     */
    public static function dispatchSafely(int $recordId): void
    {
        try {
            static::dispatch($recordId);
        } catch (Throwable $e) {
            // The class name only: messages of database or transport errors can carry data we do not want in a log.
            Log::warning('subdomain-manager: sync job could not run now; reconcile will retry', ['record' => $recordId, 'error' => $e::class]);
        }
    }

    /** @return list<int> */
    public function backoff(): array
    {
        return [10, 30, 60, 120];
    }

    public function uniqueId(): string
    {
        return 'subdomain-manager-record-'.$this->recordId;
    }

    public function handle(ExtensionSettingsRegistry $registry, Factory $http): void
    {
        $record = Record::query()->find($this->recordId);
        if ($record === null) {
            return; // deleted in the meantime
        }

        $settings = SubdomainSettings::fromRegistry($registry);
        $token = $settings->token();

        (new RecordSyncer($token === null ? null : new CloudflareClient($http, $token), $settings->syncConfig()))->sync($record);
    }

    /** Called when the last try has failed: say so on the row, with a message that is safe to show. */
    public function failed(Throwable $exception): void
    {
        $record = Record::query()->find($this->recordId);
        if ($record === null) {
            return;
        }

        $record->last_error = $exception instanceof CloudflareException ? $exception->safe : 'unexpected error while syncing; see the Panel log';
        if ($record->status !== Record::DELETING) {
            $record->status = Record::FAILED;
        }
        $record->save();

        // The class name only: messages of database or transport errors can carry data we do not want in a log.
        Log::error('subdomain-manager: sync gave up', ['record' => $this->recordId, 'error' => $exception::class]);
    }
}

<?php

declare(strict_types=1);

namespace SubdomainManager\Console;

use Illuminate\Console\Command;
use Illuminate\Database\Eloquent\Builder;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;

/**
 * Safety net (FR-S9): sends the job again for rows that are still waiting, being removed or failed and have
 * not changed for five minutes. A queue that lost a job, a Cloudflare outage that outlasted the retries and a
 * fixed token or conflict all end here. A job already queued for a row is not queued twice (ShouldBeUnique).
 */
class ReconcileCommand extends Command
{
    private const STALE_MINUTES = 5;

    protected $signature = 'subdomain-manager:reconcile';

    protected $description = 'Retry Cloudflare DNS changes that are pending, failed or waiting for a server delete';

    public function handle(): int
    {
        $count = 0;

        Record::query()
            ->whereIn('status', [Record::PENDING, Record::FAILED, Record::DELETING])
            ->where(fn (Builder $query) => $query->where('updated_at', '<=', now()->subMinutes(self::STALE_MINUTES))->orWhereNull('updated_at'))
            ->orderBy('id')
            ->each(function (Record $record) use (&$count): void {
                SyncRecord::dispatchSafely($record->id);
                $count++;
            });

        $this->info("Queued $count sync job(s).");

        return self::SUCCESS;
    }
}

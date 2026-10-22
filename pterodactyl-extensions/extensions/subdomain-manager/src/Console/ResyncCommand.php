<?php

declare(strict_types=1);

namespace SubdomainManager\Console;

use Illuminate\Console\Command;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;

/**
 * Sends the job again for every subdomain that is not being removed (FR-R8). A row whose records already match the
 * settings makes no Cloudflare call; a row whose SRV record carries another port has that record replaced. Run it
 * after a change that touches every record, such as the mode; the five-minute reconcile does the same by itself.
 */
class ResyncCommand extends Command
{
    protected $signature = 'subdomain-manager:resync';

    protected $description = 'Bring every subdomain record in line with the current settings, for example after a mode change';

    public function handle(): int
    {
        $count = 0;

        Record::query()
            ->where('status', '!=', Record::DELETING)
            ->orderBy('id')
            ->each(function (Record $record) use (&$count): void {
                SyncRecord::dispatchSafely($record->id);
                $count++;
            });

        $this->info("Queued $count sync job(s).");

        return self::SUCCESS;
    }
}

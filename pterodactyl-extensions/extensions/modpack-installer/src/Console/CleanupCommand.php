<?php

declare(strict_types=1);

namespace ModpackInstaller\Console;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use ModpackInstaller\Http\Controllers\InstallController;
use ModpackInstaller\Support\TmpStore;

/** Deletes what a crashed worker leaves on the Panel's disk, and old finished rows from the installs table (T-MI12). */
class CleanupCommand extends Command
{
    /** An archive that has waited this long belongs to a job that is gone. */
    private const TMP_AGE_SECONDS = 7200;

    private const ROW_AGE_DAYS = 30;

    protected $signature = 'modpack-installer:cleanup';

    protected $description = 'Delete old temporary modpack archives and old finished installs of the modpack-installer extension.';

    public function handle(TmpStore $tmp): int
    {
        $removed = $tmp->purge(self::TMP_AGE_SECONDS, time());

        // Rows still marked pending or running are kept: the controller already ignores the stale ones.
        DB::table(InstallController::TABLE)
            ->whereIn('status', ['completed', 'failed'])
            ->where('updated_at', '<', now()->subDays(self::ROW_AGE_DAYS))
            ->delete();

        $this->info("Deleted {$removed} old file(s).");

        return self::SUCCESS;
    }
}

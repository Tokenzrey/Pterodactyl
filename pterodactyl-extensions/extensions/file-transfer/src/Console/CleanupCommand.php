<?php

declare(strict_types=1);

namespace FileTransfer\Console;

use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\FileTransferSettings;
use Illuminate\Console\Command;

/** Deletes what a crashed worker or an abandoned upload leaves on the Panel's disk (FR-FT17, EC-FT5). */
class CleanupCommand extends Command
{
    protected $signature = 'file-transfer:cleanup';

    protected $description = 'Delete old unfinished uploads, merged files and downloads of the file-transfer extension.';

    public function handle(FileTransferSettings $settings, ChunkStore $store): int
    {
        $removed = $store->purge($settings->cleanupChunkAgeHours() * 3600, time());

        $this->info("Deleted {$removed} old file(s).");

        return self::SUCCESS;
    }
}

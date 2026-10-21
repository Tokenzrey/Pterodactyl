<?php

declare(strict_types=1);

namespace MultiNodeSync\Console;

use Illuminate\Console\Command;

class CleanupCommand extends Command
{
    protected $signature = 'multi-node-sync:cleanup';

    protected $description = 'Delete temporary migration files older than 4 hours from the multi-node-sync extension.';

    private const MAX_AGE_HOURS = 4;

    public function handle(): int
    {
        $maxAge = self::MAX_AGE_HOURS * 3600;
        $now = time();
        $deleted = 0;

        $tmpDir = storage_path('app/extensions/multi-node-sync/tmp');
        if (is_dir($tmpDir)) {
            $deleted = $this->cleanDirectory($tmpDir, $now, $maxAge);
        }

        $this->info("Deleted {$deleted} old file(s).");

        return self::SUCCESS;
    }

    private function cleanDirectory(string $dir, int $now, int $maxAge): int
    {
        $deleted = 0;
        $entries = glob($dir.'/*');
        if ($entries === false) {
            return 0;
        }

        foreach ($entries as $entry) {
            if (is_dir($entry)) {
                $deleted += $this->cleanDirectory($entry, $now, $maxAge);
                $remaining = glob($entry.'/*');
                if ($remaining === [] || $remaining === false) {
                    @rmdir($entry);
                }
            } elseif (is_file($entry) && ($now - filemtime($entry)) > $maxAge) {
                @unlink($entry);
                $deleted++;
            }
        }

        return $deleted;
    }
}

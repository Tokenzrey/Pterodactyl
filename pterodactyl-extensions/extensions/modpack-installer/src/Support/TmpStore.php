<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use InvalidArgumentException;
use RuntimeException;

/**
 * Where an archive waits on the Panel's disk between the download and the upload: one directory per job, under a root
 * that belongs to this extension (NFR-MI6). The job removes its directory when it ends; purge() removes what a worker
 * that died left behind.
 */
final class TmpStore
{
    public function __construct(private readonly string $root) {}

    /** The job's directory, created if it does not exist. */
    public function dir(string $jobId): string
    {
        $dir = "{$this->root}/tmp/{$this->safeId($jobId)}";
        if (! is_dir($dir) && ! @mkdir($dir, 0700, true) && ! is_dir($dir)) {
            throw new RuntimeException('A directory cannot be created.');
        }

        return $dir;
    }

    public function delete(string $jobId): void
    {
        $this->deleteTree("{$this->root}/tmp/{$this->safeId($jobId)}");
    }

    /** Removes every job directory whose newest file is older than $olderThanSeconds. Returns how many files went. */
    public function purge(int $olderThanSeconds, int $now): int
    {
        clearstatcache();
        $removed = 0;

        foreach (glob("{$this->root}/tmp/*", GLOB_ONLYDIR) ?: [] as $dir) {
            if ($now - $this->newestModification($dir) > $olderThanSeconds) {
                $removed += count(glob("{$dir}/*") ?: []);
                $this->deleteTree($dir);
            }
        }

        return $removed;
    }

    /** An id that is a UUID and nothing else: no dots, no slashes, no way out of the directory it names. */
    private function safeId(string $id): string
    {
        if (preg_match('/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i', $id) !== 1) {
            throw new InvalidArgumentException('The id is not a UUID.');
        }

        return strtolower($id);
    }

    private function newestModification(string $dir): int
    {
        $newest = (int) filemtime($dir);
        foreach (glob("{$dir}/*") ?: [] as $entry) {
            $newest = max($newest, (int) filemtime($entry));
        }

        return $newest;
    }

    private function deleteTree(string $dir): void
    {
        if (! is_dir($dir)) {
            return;
        }

        foreach (glob("{$dir}/*") ?: [] as $entry) {
            is_dir($entry) ? $this->deleteTree($entry) : @unlink($entry);
        }
        @rmdir($dir);
    }
}

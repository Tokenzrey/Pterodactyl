<?php

declare(strict_types=1);

namespace FileTransfer\Support;

use InvalidArgumentException;
use RuntimeException;

/**
 * Where an upload lives on the Panel's disk while it is being assembled: `chunks/<id>/<index>` for the pieces and
 * a `meta.json` saying whose upload it is, `merged/<id>/` for the assembled file, `tmp/<id>/` for a remote download.
 * Plain files on disk, written and merged as streams, never held in memory whole (NFR-FT2, NFR-FT3).
 *
 * Every id is checked before it becomes part of a path, so an id from a request can never point elsewhere.
 */
final class ChunkStore
{
    public function __construct(private readonly string $root) {}

    /**
     * Starts an upload, or confirms a later chunk belongs to it. An upload id that is already used by another server,
     * another file name or another total is a conflict, never a silent overwrite (EC-FT3, NFR-FT10).
     */
    public function claim(string $uploadId, string $serverUuid, string $filename, int $totalChunks): ?string
    {
        $dir = $this->chunkDir($uploadId);
        $this->makeDirectory($dir);

        $handle = fopen("{$dir}/meta.json", 'c+');
        if ($handle === false) {
            throw new RuntimeException('The upload record cannot be opened.');
        }

        try {
            flock($handle, LOCK_EX);
            $raw = stream_get_contents($handle);

            if ($raw === '' || $raw === false) {
                fwrite($handle, json_encode(['server' => $serverUuid, 'filename' => $filename, 'total_chunks' => $totalChunks], JSON_THROW_ON_ERROR));

                return null;
            }

            $meta = json_decode($raw, true);

            return is_array($meta) && ($meta['server'] ?? null) === $serverUuid && ($meta['filename'] ?? null) === $filename && ($meta['total_chunks'] ?? null) === $totalChunks
                ? null
                : 'upload_id_conflict';
        } finally {
            flock($handle, LOCK_UN);
            fclose($handle);
        }
    }

    /** @return array{server: string, filename: string, total_chunks: int}|null */
    public function meta(string $uploadId): ?array
    {
        $file = $this->chunkDir($uploadId).'/meta.json';
        $raw = is_file($file) ? file_get_contents($file) : false;
        $meta = $raw === false ? null : json_decode($raw, true);

        return is_array($meta) && is_string($meta['server'] ?? null) && is_string($meta['filename'] ?? null) && is_int($meta['total_chunks'] ?? null) ? $meta : null;
    }

    /** Written under a temporary name and renamed, so a half-written chunk is never seen. A repeat replaces the first (EC-FT2). */
    public function store(string $uploadId, int $index, string $bytes): void
    {
        $dir = $this->chunkDir($uploadId);
        $this->makeDirectory($dir);

        $part = "{$dir}/.{$index}.part";
        if (file_put_contents($part, $bytes) === false || ! rename($part, "{$dir}/{$index}")) {
            @unlink($part);

            throw new RuntimeException('The chunk cannot be written.');
        }
    }

    /** @return list<int> */
    public function missing(string $uploadId, int $totalChunks): array
    {
        $dir = $this->chunkDir($uploadId);
        $missing = [];
        for ($index = 0; $index < $totalChunks; $index++) {
            if (! is_file("{$dir}/{$index}")) {
                $missing[] = $index;
            }
        }

        return $missing;
    }

    /** The bytes received so far, which is the size the merged file will have. */
    public function receivedBytes(string $uploadId, int $totalChunks): int
    {
        $dir = $this->chunkDir($uploadId);
        $bytes = 0;
        for ($index = 0; $index < $totalChunks; $index++) {
            $bytes += is_file("{$dir}/{$index}") ? (int) filesize("{$dir}/{$index}") : 0;
        }

        return $bytes;
    }

    /** @throws RuntimeException when a chunk is missing: a merge never writes a file with a hole in it */
    public function mergeTo(string $uploadId, int $totalChunks, string $outputPath): void
    {
        $dir = $this->chunkDir($uploadId);
        $this->makeDirectory(dirname($outputPath));

        $output = fopen($outputPath, 'wb');
        if ($output === false) {
            throw new RuntimeException('The merged file cannot be created.');
        }

        try {
            for ($index = 0; $index < $totalChunks; $index++) {
                $input = is_file("{$dir}/{$index}") ? fopen("{$dir}/{$index}", 'rb') : false;
                if ($input === false) {
                    throw new RuntimeException("Chunk {$index} is missing.");
                }

                try {
                    stream_copy_to_stream($input, $output);
                } finally {
                    fclose($input);
                }
            }
        } catch (RuntimeException $exception) {
            fclose($output);
            @unlink($outputPath);

            throw $exception;
        }

        fclose($output);
    }

    public function mergedPath(string $uploadId, string $filename): string
    {
        if (! ChunkValidator::validateFilename($filename)) {
            throw new InvalidArgumentException('The file name is not safe to use in a path.');
        }

        return $this->mergedDir($uploadId)."/{$filename}";
    }

    public function delete(string $uploadId): void
    {
        $this->deleteTree($this->chunkDir($uploadId));
    }

    public function deleteMerged(string $uploadId): void
    {
        $this->deleteTree($this->mergedDir($uploadId));
    }

    public function tmpDir(string $jobId): string
    {
        return "{$this->root}/tmp/{$this->safeId($jobId)}";
    }

    public function deleteTmp(string $jobId): void
    {
        $this->deleteTree($this->tmpDir($jobId));
    }

    /**
     * Removes every upload, merged file and download whose newest file is older than $olderThanSeconds: what a crashed
     * worker or an abandoned upload leaves behind (FR-FT17, NFR-FT5). Returns the number of files removed.
     */
    public function purge(int $olderThanSeconds, int $now): int
    {
        clearstatcache();
        $removed = 0;

        foreach (['chunks', 'merged', 'tmp'] as $area) {
            foreach (glob("{$this->root}/{$area}/*", GLOB_ONLYDIR) ?: [] as $dir) {
                if ($now - $this->newestModification($dir) > $olderThanSeconds) {
                    $removed += $this->countFiles($dir);
                    $this->deleteTree($dir);
                }
            }
        }

        return $removed;
    }

    private function chunkDir(string $uploadId): string
    {
        return "{$this->root}/chunks/{$this->safeId($uploadId)}";
    }

    private function mergedDir(string $uploadId): string
    {
        return "{$this->root}/merged/{$this->safeId($uploadId)}";
    }

    /** An id that is a UUID and nothing else: no dots, no slashes, no way out of the directory it names. */
    private function safeId(string $id): string
    {
        if (preg_match('/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i', $id) !== 1) {
            throw new InvalidArgumentException('The id is not a UUID.');
        }

        return strtolower($id);
    }

    private function makeDirectory(string $dir): void
    {
        if (! is_dir($dir) && ! @mkdir($dir, 0700, true) && ! is_dir($dir)) {
            throw new RuntimeException('A directory cannot be created.');
        }
    }

    private function newestModification(string $dir): int
    {
        $newest = (int) filemtime($dir);
        foreach (new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS)) as $file) {
            $newest = max($newest, (int) $file->getMTime());
        }

        return $newest;
    }

    private function countFiles(string $dir): int
    {
        $count = 0;
        foreach (new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS)) as $file) {
            $count += $file->isFile() ? 1 : 0;
        }

        return $count;
    }

    private function deleteTree(string $dir): void
    {
        if (! is_dir($dir)) {
            return;
        }

        $items = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS), \RecursiveIteratorIterator::CHILD_FIRST);
        foreach ($items as $item) {
            $item->isDir() && ! $item->isLink() ? @rmdir($item->getPathname()) : @unlink($item->getPathname());
        }
        @rmdir($dir);
    }
}

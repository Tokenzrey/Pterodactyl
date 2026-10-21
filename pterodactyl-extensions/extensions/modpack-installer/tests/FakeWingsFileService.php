<?php

declare(strict_types=1);

namespace ModpackInstaller\Tests;

use Closure;
use ModpackInstaller\Support\WingsException;
use ModpackInstaller\Support\WingsFileService;

/** Wings without Wings: remembers what it was asked and can be made to refuse any of it. */
final class FakeWingsFileService implements WingsFileService
{
    /** @var list<array{server: string, path: string, content: string}> the bytes as they were when the upload happened */
    public array $uploads = [];

    /** @var list<array{server: string, path: string}> */
    public array $decompressed = [];

    /** @var list<array{server: string, path: string}> */
    public array $deleted = [];

    /** @var list<string> what listFiles reports, as if the archive had been extracted */
    public array $entries = [];

    /** @var list<string> every call, in order, as "method path" */
    public array $calls = [];

    /** @var (Closure(string): void)|null called with each call as "method path", before it is answered */
    public ?Closure $onCall = null;

    public ?WingsException $failUpload = null;

    public ?WingsException $failDecompress = null;

    public ?WingsException $failList = null;

    /** @var array<string, WingsException> by remote path */
    public array $failDelete = [];

    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void
    {
        $this->record("upload {$remotePath}");

        if ($this->failUpload !== null) {
            throw $this->failUpload;
        }

        $this->uploads[] = ['server' => $serverUuid, 'path' => $remotePath, 'content' => (string) file_get_contents($localFilePath)];
    }

    public function decompress(string $serverUuid, string $remotePath): void
    {
        $this->record("decompress {$remotePath}");

        if ($this->failDecompress !== null) {
            throw $this->failDecompress;
        }

        $this->decompressed[] = ['server' => $serverUuid, 'path' => $remotePath];
    }

    public function listFiles(string $serverUuid, string $directory): array
    {
        $this->record("list {$directory}");

        if ($this->failList !== null) {
            throw $this->failList;
        }

        return $this->entries;
    }

    public function deleteFile(string $serverUuid, string $remotePath): void
    {
        $this->record("delete {$remotePath}");

        if (isset($this->failDelete[$remotePath])) {
            throw $this->failDelete[$remotePath];
        }

        $this->deleted[] = ['server' => $serverUuid, 'path' => $remotePath];
    }

    private function record(string $call): void
    {
        $this->calls[] = $call;

        if ($this->onCall !== null) {
            ($this->onCall)($call);
        }
    }
}

<?php

declare(strict_types=1);

namespace FileTransfer\Tests;

use Closure;
use FileTransfer\Support\TransferException;
use FileTransfer\Support\WingsFileService;

/** Wings without Wings: remembers what was uploaded (the bytes as they were when it happened) and can be made to refuse. */
final class FakeWingsFileService implements WingsFileService
{
    /** @var list<array{server: string, path: string, content: string}> */
    public array $uploads = [];

    public ?TransferException $failWith = null;

    /** @var (Closure(string, string): void)|null called with the server and remote path as an upload starts */
    public ?Closure $onUpload = null;

    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void
    {
        if ($this->onUpload !== null) {
            ($this->onUpload)($serverUuid, $remotePath);
        }

        if ($this->failWith !== null) {
            throw $this->failWith;
        }

        $this->uploads[] = ['server' => $serverUuid, 'path' => $remotePath, 'content' => (string) file_get_contents($localFilePath)];
    }
}

<?php

declare(strict_types=1);

namespace FileTransfer\Support;

/** What file-transfer needs from a server's files. A seam so that tests never talk to Wings (NFR-FT9). */
interface WingsFileService
{
    /**
     * Puts the local file at $remotePath on the server, streaming it.
     *
     * @throws TransferException upload_failed
     */
    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void;
}

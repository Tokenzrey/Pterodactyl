<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

/**
 * What the installer needs from a server's files. Every path is absolute inside the server ("/mods/pack.zip").
 * A seam so that tests never talk to Wings (NFR-MI8).
 */
interface WingsFileService
{
    /**
     * Streams a local file onto the server, replacing whatever is at $remotePath.
     *
     * @throws WingsException
     */
    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void;

    /**
     * Extracts an archive in the folder it is in.
     *
     * @throws WingsException
     */
    public function decompress(string $serverUuid, string $remotePath): void;

    /**
     * The names of the entries directly inside a folder.
     *
     * @return list<string>
     *
     * @throws WingsException
     */
    public function listFiles(string $serverUuid, string $directory): array;

    /**
     * Deletes one file.
     *
     * @throws WingsException
     */
    public function deleteFile(string $serverUuid, string $remotePath): void;
}

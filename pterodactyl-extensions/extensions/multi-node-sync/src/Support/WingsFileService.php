<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

/**
 * The file operations a migration needs on a server's node. Every path is absolute inside the server ("/mods/a.zip").
 * A seam so the job can be tested without a node.
 */
interface WingsFileService
{
    /**
     * Packs every top-level entry of the server into one archive in its root and returns the archive's path.
     *
     * @throws WingsException
     */
    public function archive(string $serverUuid): string;

    /**
     * Streams a file from the server into a local file.
     *
     * @throws WingsException
     */
    public function download(string $serverUuid, string $remotePath, string $localPath): void;

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
     * Deletes a file or a folder, with everything in it.
     *
     * @throws WingsException
     */
    public function deleteFile(string $serverUuid, string $remotePath): void;
}

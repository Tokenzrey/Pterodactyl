<?php

declare(strict_types=1);

namespace FileTransfer\Support;

use GuzzleHttp\Psr7\Utils;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Daemon\DaemonConnection;

/**
 * Writes a file to a server through the Panel's own authenticated connection to Wings, the same call the Panel's
 * file editor makes. The body is a stream of the local file, so a large file is never held in memory.
 */
final class PanelWingsFileService implements WingsFileService
{
    /** A large file takes a while; the connection's usual timeout is for small calls. */
    private const UPLOAD_TIMEOUT = 3600;

    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void
    {
        $server = Server::query()->with('node')->where('uuid', $serverUuid)->first();
        $handle = is_file($localFilePath) ? fopen($localFilePath, 'rb') : false;

        if ($server === null || $handle === false) {
            throw new TransferException('upload_failed');
        }

        try {
            DaemonConnection::forNode($server->node)->request('POST', "/api/servers/{$server->uuid}/files/write", [
                'query' => ['file' => $remotePath],
                'body' => Utils::streamFor($handle),
                'timeout' => self::UPLOAD_TIMEOUT,
            ]);
        } catch (DaemonConnectionException) {
            // Wings refused or could not be reached (a full disk, a missing folder, a node that is down).
            throw new TransferException('upload_failed', true);
        } finally {
            if (is_resource($handle)) {
                fclose($handle);
            }
        }
    }
}

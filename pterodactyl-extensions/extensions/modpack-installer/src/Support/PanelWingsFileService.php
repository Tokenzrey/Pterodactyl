<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use GuzzleHttp\Psr7\Utils;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Response;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Daemon\DaemonConnection;

/**
 * Talks to a server's node through the Panel's own authenticated connection, with the calls the Panel's file manager
 * makes, so the node token never leaves the Panel. The archive streams from disk; it is never held whole.
 */
final class PanelWingsFileService implements WingsFileService
{
    /** A large pack takes a while to arrive and to unpack; the connection's usual timeout is for small calls. */
    private const UPLOAD_TIMEOUT = 3600;

    private const ARCHIVE_TIMEOUT = 900;

    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void
    {
        $this->assertAbsolute($remotePath);

        $handle = is_file($localFilePath) ? fopen($localFilePath, 'rb') : false;
        if ($handle === false) {
            throw new WingsException('upload_failed');
        }

        // The stream owns the handle from here on and closes it.
        $body = Utils::streamFor($handle);

        try {
            $this->call($serverUuid, 'POST', 'files/write', 'upload_failed', [
                'query' => ['file' => $remotePath],
                'body' => $body,
                'timeout' => self::UPLOAD_TIMEOUT,
            ]);
        } finally {
            $body->close();
        }
    }

    public function decompress(string $serverUuid, string $remotePath): void
    {
        $this->assertAbsolute($remotePath);

        $this->call($serverUuid, 'POST', 'files/decompress', 'extract_failed', [
            'json' => ['root' => dirname($remotePath), 'file' => basename($remotePath)],
            'timeout' => self::ARCHIVE_TIMEOUT,
        ]);
    }

    public function listFiles(string $serverUuid, string $directory): array
    {
        $this->assertAbsolute($directory);

        $entries = $this->call($serverUuid, 'GET', 'files/list-directory', 'list_failed', [
            'query' => ['directory' => $directory],
        ])->json();

        if (! is_array($entries)) {
            throw new WingsException('list_failed');
        }

        $names = [];
        foreach ($entries as $entry) {
            if (is_array($entry) && is_string($entry['name'] ?? null)) {
                $names[] = $entry['name'];
            }
        }

        return $names;
    }

    public function deleteFile(string $serverUuid, string $remotePath): void
    {
        $this->assertAbsolute($remotePath);

        $this->call($serverUuid, 'POST', 'files/delete', 'delete_failed', [
            'json' => ['root' => dirname($remotePath), 'files' => [basename($remotePath)]],
        ]);
    }

    /** @param array<string, mixed> $options */
    private function call(string $serverUuid, string $method, string $endpoint, string $reason, array $options): Response
    {
        $server = Server::query()->with('node')->where('uuid', $serverUuid)->first();
        if ($server === null) {
            throw new WingsException('server_not_found');
        }

        try {
            return DaemonConnection::forNode($server->node)->request($method, "/api/servers/{$server->uuid}/{$endpoint}", $options);
        } catch (DaemonConnectionException $exception) {
            // Refused by Wings, or no answer at all: only the second is worth another try.
            throw new WingsException($reason, $exception->getPrevious() instanceof ConnectionException);
        }
    }

    /** Paths reach Wings absolute and inside the server: no "..", no empty or dot segments, no odd characters. */
    private function assertAbsolute(string $path): void
    {
        if (preg_match('#\A/([A-Za-z0-9_.-]+/?)*\z#', $path) !== 1 || str_contains($path, '..') || str_contains($path, '/./') || str_contains($path, '//')) {
            throw new WingsException('invalid_path');
        }
    }
}

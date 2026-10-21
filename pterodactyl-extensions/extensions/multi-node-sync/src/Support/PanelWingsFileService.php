<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use GuzzleHttp\Psr7\Utils;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Response;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Daemon\DaemonConnection;
use RuntimeException;

/**
 * Talks to a server's node through the Panel's own authenticated connection, with the same calls the Panel's file
 * manager makes, so the node token never leaves the Panel. Large files stream in both directions.
 */
final class PanelWingsFileService implements WingsFileService
{
    /** Compressing and extracting can take minutes; the connection's usual timeout is for small calls. */
    private const ARCHIVE_TIMEOUT = 900;

    private const TRANSFER_TIMEOUT = 3600;

    public function archive(string $serverUuid): string
    {
        $names = $this->listFiles($serverUuid, '/');
        if ($names === []) {
            throw new WingsException('archive_failed');
        }

        $file = $this->call($serverUuid, 'POST', 'files/compress', 'archive_failed', [
            'json' => ['root' => '/', 'files' => $names],
            'timeout' => self::ARCHIVE_TIMEOUT,
        ])->json();

        $name = is_array($file) ? ($file['name'] ?? null) : null;
        if (! is_string($name) || preg_match('/\A[A-Za-z0-9._-]+\z/', $name) !== 1) {
            throw new WingsException('archive_failed');
        }

        return "/{$name}";
    }

    public function download(string $serverUuid, string $remotePath, string $localPath): void
    {
        $this->assertAbsolute($remotePath);

        $handle = @fopen($localPath, 'wb');
        if ($handle === false) {
            throw new WingsException('disk_full');
        }

        // The stream owns the handle from here on and closes it.
        $sink = Utils::streamFor($handle);

        try {
            $response = $this->call($serverUuid, 'GET', 'files/contents', 'download_failed', [
                'query' => ['file' => $remotePath],
                'stream' => true,
                'timeout' => self::TRANSFER_TIMEOUT,
            ]);

            Utils::copyToStream($response->toPsrResponse()->getBody(), $sink);
        } catch (RuntimeException $exception) {
            // A local write that fails (a full disk) surfaces as a RuntimeException from the stream, not from Wings.
            throw $exception instanceof WingsException ? $exception : new WingsException('disk_full');
        } finally {
            $sink->close();
        }
    }

    public function upload(string $serverUuid, string $localFilePath, string $remotePath): void
    {
        $this->assertAbsolute($remotePath);

        $handle = is_file($localFilePath) ? fopen($localFilePath, 'rb') : false;
        if ($handle === false) {
            throw new WingsException('upload_failed');
        }

        $body = Utils::streamFor($handle);

        try {
            $this->call($serverUuid, 'POST', 'files/write', 'upload_failed', [
                'query' => ['file' => $remotePath],
                'body' => $body,
                'timeout' => self::TRANSFER_TIMEOUT,
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
        $server = $this->server($serverUuid);

        try {
            return DaemonConnection::forNode($server->node)->request($method, "/api/servers/{$server->uuid}/{$endpoint}", $options);
        } catch (DaemonConnectionException $exception) {
            // Refused by Wings, or no answer at all: the job reports those two differently.
            throw new WingsException($reason, $exception->getPrevious() instanceof ConnectionException);
        }
    }

    private function server(string $serverUuid): Server
    {
        $server = Server::query()->with('node')->where('uuid', $serverUuid)->first();
        if ($server === null) {
            throw new WingsException('server_not_found');
        }

        return $server;
    }

    /** Paths reach Wings absolute and inside the server: no "..", no empty or dot segments, no odd characters. */
    private function assertAbsolute(string $path): void
    {
        if (preg_match('#\A/([A-Za-z0-9_.-]+/?)*\z#', $path) !== 1 || str_contains($path, '..') || str_contains($path, '/./') || str_contains($path, '//')) {
            throw new WingsException('invalid_path');
        }
    }
}

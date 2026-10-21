<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Response;

final class CurseForgeClient
{
    public const PAGE_SIZE = 20;

    /** CurseForge allows no result past the ten-thousandth. */
    private const MAX_INDEX = 10000;

    private const MINECRAFT_GAME_ID = 432;

    private const MODPACKS_CLASS_ID = 4471;

    /** CurseForge's numeric ModLoaderType. */
    private const LOADERS = ['forge' => 1, 'fabric' => 4, 'quilt' => 5, 'neoforge' => 6];

    /** The loader names as they appear among a file's `gameVersions`. */
    private const LOADER_NAMES = ['forge' => 'forge', 'fabric' => 'fabric', 'quilt' => 'quilt', 'neoforge' => 'neoforge'];

    public function __construct(
        private readonly Factory $http,
        private readonly string $apiKey,
    ) {}

    /** Whether a search for this page is one CurseForge will answer. */
    public static function pageInRange(int $page): bool
    {
        return $page >= 0 && ($page + 1) * self::PAGE_SIZE <= self::MAX_INDEX;
    }

    public function search(string $query, ?string $gameVersion, ?string $loader, int $page): ModpackPage
    {
        $params = [
            'gameId' => self::MINECRAFT_GAME_ID,
            'classId' => self::MODPACKS_CLASS_ID,
            'searchFilter' => $query,
            'index' => $page * self::PAGE_SIZE,
            'pageSize' => self::PAGE_SIZE,
        ];
        if ($gameVersion !== null) {
            $params['gameVersion'] = $gameVersion;
            // CurseForge only applies a loader together with a game version.
            if ($loader !== null && isset(self::LOADERS[strtolower($loader)])) {
                $params['modLoaderType'] = self::LOADERS[strtolower($loader)];
            }
        }

        $body = $this->get('mods/search', $params);
        $items = $body['data'] ?? null;
        if (! is_array($items) || ! array_is_list($items)) {
            throw ModpackSourceException::unavailable();
        }

        $results = [];
        foreach ($items as $item) {
            if (is_array($item) && isset($item['id'], $item['name']) && is_int($item['id'])) {
                $results[] = $this->result($item);
            }
        }

        $total = $body['pagination']['totalCount'] ?? null;

        return new ModpackPage($results, is_int($total) && $total >= 0 ? min($total, self::MAX_INDEX) : count($results));
    }

    /** The file with this id, or null when the project has no such file (or it can no longer be downloaded). */
    public function file(string $projectId, string $fileId): ?ResolvedFile
    {
        $this->assertId($projectId);
        $this->assertId($fileId);

        $body = $this->get("mods/{$projectId}/files/{$fileId}", [], notFoundIsNull: true);
        if ($body === null) {
            return null;
        }

        $file = $body['data'] ?? null;
        if (! is_array($file) || (string) ($file['id'] ?? '') !== $fileId || ! is_string($file['fileName'] ?? null)) {
            throw ModpackSourceException::unavailable();
        }
        if (($file['isAvailable'] ?? true) === false) {
            return null;
        }

        $url = $file['downloadUrl'] ?? null;
        $length = $file['fileLength'] ?? null;

        return new ResolvedFile(
            fileId: $fileId,
            name: $file['fileName'],
            isServerPack: ($file['isServerPack'] ?? false) === true,
            downloadUrl: is_string($url) && $url !== '' ? $url : null,
            sizeBytes: is_int($length) && $length >= 0 ? $length : null,
            sha1: $this->sha1($file['hashes'] ?? []),
        );
    }

    /** @param array<string, mixed> $item */
    private function result(array $item): ModpackResult
    {
        $logo = $item['logo']['thumbnailUrl'] ?? null;
        $files = [];
        foreach (is_array($item['latestFiles'] ?? null) ? $item['latestFiles'] : [] as $file) {
            if (is_array($file) && ($entry = $this->offered($file)) !== null) {
                $files[] = $entry;
            }
            if (count($files) === 5) {
                break;
            }
        }

        return new ModpackResult(
            source: ModpackSource::CurseForge,
            projectId: (string) $item['id'],
            name: (string) $item['name'],
            summary: is_string($item['summary'] ?? null) ? $item['summary'] : '',
            downloads: is_numeric($item['downloadCount'] ?? null) ? (int) $item['downloadCount'] : 0,
            iconUrl: is_string($logo) && str_starts_with($logo, 'https://') ? $logo : null,
            latestFiles: $files,
        );
    }

    /**
     * A file a result offers. A client pack is offered as the server pack it points to (`serverPackFileId`): that is the
     * file to install. A file that is itself a server pack is offered as it is. Anything else is shown, not installable.
     *
     * @param  array<string, mixed>  $file
     */
    private function offered(array $file): ?ModpackFile
    {
        if (! is_int($file['id'] ?? null) || ! is_string($file['fileName'] ?? null) || ($file['isAvailable'] ?? true) === false) {
            return null;
        }

        $serverPackId = $file['serverPackFileId'] ?? null;
        $isServerPack = ($file['isServerPack'] ?? false) === true;
        $versions = is_array($file['gameVersions'] ?? null) ? array_filter($file['gameVersions'], is_string(...)) : [];
        $length = $file['fileLength'] ?? null;

        return new ModpackFile(
            fileId: (string) ($isServerPack ? $file['id'] : (is_int($serverPackId) && $serverPackId > 0 ? $serverPackId : $file['id'])),
            name: $file['fileName'],
            gameVersion: $this->gameVersion($versions),
            loader: $this->loader($versions),
            isServerPack: $isServerPack || (is_int($serverPackId) && $serverPackId > 0),
            fileSizeMb: is_int($length) ? round($length / 1048576, 2) : null,
        );
    }

    /** @param list<string>|array<int, string> $versions */
    private function gameVersion(array $versions): ?string
    {
        foreach ($versions as $version) {
            if (preg_match('/\A\d+\.\d+(\.\d+)?\z/', $version) === 1) {
                return $version;
            }
        }

        return null;
    }

    /** @param list<string>|array<int, string> $versions */
    private function loader(array $versions): ?string
    {
        foreach ($versions as $version) {
            if (isset(self::LOADER_NAMES[strtolower($version)])) {
                return strtolower($version);
            }
        }

        return null;
    }

    private function sha1(mixed $hashes): ?string
    {
        foreach (is_array($hashes) ? $hashes : [] as $hash) {
            if (is_array($hash) && ($hash['algo'] ?? null) === 1 && is_string($hash['value'] ?? null) && preg_match('/\A[0-9a-fA-F]{40}\z/', $hash['value']) === 1) {
                return strtolower($hash['value']);
            }
        }

        return null;
    }

    /** Ids go into a URL path; the controller checks them too, but this class does not rely on that. */
    private function assertId(string $id): void
    {
        if (preg_match(ModpackSource::CurseForge->idPattern(), $id) !== 1) {
            throw ModpackSourceException::unavailable();
        }
    }

    /**
     * @param  array<string, mixed>  $query
     * @return array<string, mixed>|null null only for a 404 when $notFoundIsNull
     */
    private function get(string $path, array $query, bool $notFoundIsNull = false): ?array
    {
        try {
            $response = $this->http
                ->withHeaders(['X-API-Key' => $this->apiKey, 'Accept' => 'application/json'])
                ->withOptions(['verify' => true])
                ->timeout(30)
                ->connectTimeout(10)
                ->withoutRedirecting()
                ->get(ModpackSource::CurseForge->baseUrl().$path, $query);
        } catch (ConnectionException) {
            throw ModpackSourceException::unavailable();
        }

        if ($notFoundIsNull && $response->status() === 404) {
            return null;
        }

        return $this->body($response);
    }

    /** @return array<string, mixed> */
    private function body(Response $response): array
    {
        $body = $response->status() === 200 ? $response->json() : null;
        if (! is_array($body)) {
            throw ModpackSourceException::unavailable();
        }

        return $body;
    }
}

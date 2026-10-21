<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;

/**
 * Searches Modrinth's modpacks. It cannot offer a server pack to install, because Modrinth has none (see
 * ModpackSource::hasServerPacks): a hit carries no files.
 */
final class ModrinthClient
{
    public const PAGE_SIZE = 20;

    /** Modrinth blocks a client that does not name itself. */
    private const USER_AGENT = 'pterodactyl-modpack-installer/1.0.0';

    private const LOADERS = ['forge', 'fabric', 'quilt', 'neoforge'];

    public function __construct(private readonly Factory $http) {}

    public function search(string $query, ?string $gameVersion, ?string $loader, int $page): ModpackPage
    {
        $params = [
            'query' => $query,
            'facets' => json_encode($this->facets($gameVersion, $loader), JSON_THROW_ON_ERROR),
            'offset' => $page * self::PAGE_SIZE,
            'limit' => self::PAGE_SIZE,
        ];

        try {
            $response = $this->http
                ->withHeaders(['Accept' => 'application/json', 'User-Agent' => self::USER_AGENT])
                ->withOptions(['verify' => true])
                ->timeout(30)
                ->connectTimeout(10)
                ->withoutRedirecting()
                ->get(ModpackSource::Modrinth->baseUrl().'search', $params);
        } catch (ConnectionException) {
            throw ModpackSourceException::unavailable();
        }

        $body = $response->status() === 200 ? $response->json() : null;
        $hits = is_array($body) ? ($body['hits'] ?? null) : null;
        if (! is_array($hits) || ! array_is_list($hits)) {
            throw ModpackSourceException::unavailable();
        }

        $results = [];
        foreach ($hits as $hit) {
            if (! is_array($hit) || ! is_string($hit['project_id'] ?? null) || preg_match(ModpackSource::Modrinth->idPattern(), $hit['project_id']) !== 1 || ! is_string($hit['title'] ?? null)) {
                continue;
            }

            $icon = $hit['icon_url'] ?? null;
            $results[] = new ModpackResult(
                source: ModpackSource::Modrinth,
                projectId: $hit['project_id'],
                name: $hit['title'],
                summary: is_string($hit['description'] ?? null) ? $hit['description'] : '',
                downloads: is_numeric($hit['downloads'] ?? null) ? (int) $hit['downloads'] : 0,
                iconUrl: is_string($icon) && str_starts_with($icon, 'https://') ? $icon : null,
                latestFiles: [],
            );
        }

        $total = $body['total_hits'] ?? null;

        return new ModpackPage($results, is_int($total) && $total >= 0 ? $total : count($results));
    }

    /**
     * Modpacks only; each inner list is an OR and the outer list an AND. A loader is a category on Modrinth.
     *
     * @return list<list<string>>
     */
    private function facets(?string $gameVersion, ?string $loader): array
    {
        $facets = [['project_type:modpack']];
        if ($gameVersion !== null) {
            $facets[] = ['versions:'.$gameVersion];
        }
        if ($loader !== null && in_array(strtolower($loader), self::LOADERS, true)) {
            $facets[] = ['categories:'.strtolower($loader)];
        }

        return $facets;
    }
}

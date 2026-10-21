<?php

declare(strict_types=1);

namespace ModpackInstaller\Http\Controllers;

use Illuminate\Contracts\Cache\LockTimeoutException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\Cache;
use ModpackInstaller\Support\CurseForgeClient;
use ModpackInstaller\Support\ModpackPage;
use ModpackInstaller\Support\ModpackSearchCache;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Support\ModpackSourceException;
use ModpackInstaller\Support\ModrinthClient;
use Pterodactyl\Models\Server;

/** Searches CurseForge or Modrinth for modpacks (FR-MI1 to FR-MI3, FR-MI16). */
final class SearchController extends Controller
{
    public function search(Request $request, Server $server, ModpackSettings $settings, Factory $http): JsonResponse
    {
        abort_unless($request->user()->can('ext.modpack-installer.install', $server), 403);

        $input = $request->validate([
            'source' => ['required', 'string', 'in:curseforge,modrinth'],
            'query' => ['required', 'string', 'min:1', 'max:100'],
            'game_version' => ['nullable', 'string', 'max:20', 'regex:/\A[0-9A-Za-z.\-]+\z/'],
            'loader' => ['nullable', 'string', 'in:forge,fabric,quilt,neoforge'],
            'page' => ['nullable', 'integer', 'min:0', 'max:499'],
        ]);

        $source = ModpackSource::from($input['source']);
        $query = trim($input['query']);
        $gameVersion = $input['game_version'] ?? null;
        $loader = $input['loader'] ?? null;
        $page = (int) ($input['page'] ?? 0);

        if ($query === '') {
            return response()->json(['error' => 'invalid_query'], 422);
        }
        if ($source === ModpackSource::CurseForge && ! CurseForgeClient::pageInRange($page)) {
            return response()->json(['error' => 'invalid_page'], 422);
        }
        if ($source->requiresApiKey() && $settings->curseforgeApiKey() === null) {
            return response()->json(['error' => 'curseforge_not_configured'], 503);
        }

        $seconds = $settings->searchCacheSeconds();
        $key = ModpackSearchCache::key($source, $query, $gameVersion, $loader, $page);

        if ($seconds > 0 && is_array($cached = Cache::get($key))) {
            return response()->json($cached);
        }

        // One caller asks the source; the others wait for the answer to land in the cache.
        $lock = $seconds > 0 ? Cache::lock("{$key}:lock", 15) : null;

        try {
            $lock?->block(8);
            if ($lock !== null && is_array($cached = Cache::get($key))) {
                return response()->json($cached);
            }

            $payload = $this->payload($this->ask($source, $settings, $http, $query, $gameVersion, $loader, $page), $page);
        } catch (ModpackSourceException $exception) {
            return response()->json(['error' => $exception->errorCode()], 503);
        } catch (LockTimeoutException) {
            return response()->json(['error' => 'source_unavailable'], 503);
        } finally {
            $lock?->release();
        }

        if ($seconds > 0) {
            Cache::put($key, $payload, $seconds);
        }

        return response()->json($payload);
    }

    private function ask(ModpackSource $source, ModpackSettings $settings, Factory $http, string $query, ?string $gameVersion, ?string $loader, int $page): ModpackPage
    {
        return match ($source) {
            ModpackSource::CurseForge => (new CurseForgeClient($http, (string) $settings->curseforgeApiKey()))->search($query, $gameVersion, $loader, $page),
            ModpackSource::Modrinth => (new ModrinthClient($http))->search($query, $gameVersion, $loader, $page),
        };
    }

    /** @return array<string, mixed> */
    private function payload(ModpackPage $page, int $number): array
    {
        return [
            'results' => array_map(static fn ($result): array => [
                'source' => $result->source->value,
                'project_id' => $result->projectId,
                'name' => $result->name,
                'summary' => $result->summary,
                'downloads' => $result->downloads,
                'icon_url' => $result->iconUrl,
                'latest_files' => array_map(static fn ($file): array => [
                    'file_id' => $file->fileId,
                    'name' => $file->name,
                    'game_version' => $file->gameVersion,
                    'loader' => $file->loader,
                    'is_server_pack' => $file->isServerPack,
                    'file_size_mb' => $file->fileSizeMb,
                ], $result->latestFiles),
            ], $page->results),
            'total' => $page->total,
            'page' => $number,
        ];
    }
}

<?php

declare(strict_types=1);

namespace ModpackInstaller\Tests;

use Pterodactyl\Models\Server;
use Pterodactyl\Models\Subuser;
use Pterodactyl\Models\User;

/** What the tests share: CurseForge answers as the API shapes them, and users with exactly some permissions. */
final class Fixtures
{
    public const INSTALL = 'ext.modpack-installer.install';

    public const CDN = 'https://edge.forgecdn.net/files/4000/001/atm9-server.zip';

    public static function url(Server $server, string $tail): string
    {
        return "/api/client/servers/{$server->uuid}/extensions/modpack-installer/{$tail}";
    }

    /** A file as CurseForge describes it. @param array<string, mixed> $over @return array<string, mixed> */
    public static function file(array $over = []): array
    {
        return [
            'id' => 4001,
            'fileName' => 'atm9-1.0.0.zip',
            'isAvailable' => true,
            'fileLength' => 1048576,
            'downloadUrl' => self::CDN,
            'gameVersions' => ['1.20.1', 'Forge', 'Client'],
            'hashes' => [['value' => sha1('pack'), 'algo' => 1], ['value' => md5('pack'), 'algo' => 2]],
            'isServerPack' => false,
            'serverPackFileId' => 4002,
            ...$over,
        ];
    }

    /** The server pack of the client file above, as the file endpoint returns it. @param array<string, mixed> $over @return array<string, mixed> */
    public static function serverPack(array $over = []): array
    {
        return self::file(['id' => 4002, 'fileName' => 'atm9-server-1.0.0.zip', 'isServerPack' => true, 'serverPackFileId' => null, 'hashes' => [['value' => sha1('pack'), 'algo' => 1]], ...$over]);
    }

    /** One project in a search answer. @param array<string, mixed> $over @return array<string, mixed> */
    public static function mod(array $over = []): array
    {
        return [
            'id' => 123,
            'name' => 'All the Mods 9',
            'summary' => 'Everything.',
            'downloadCount' => 5000000,
            'logo' => ['thumbnailUrl' => 'https://media.forgecdn.net/avatars/thumbnails/1/2/64/64/atm9.png'],
            'latestFiles' => [self::file()],
            ...$over,
        ];
    }

    /** A search answer. @param list<array<string, mixed>> $mods @return array<string, mixed> */
    public static function search(array $mods, ?int $total = null): array
    {
        return ['data' => $mods, 'pagination' => ['index' => 0, 'pageSize' => 20, 'resultCount' => count($mods), 'totalCount' => $total ?? count($mods)]];
    }

    /** A Modrinth search hit. @param array<string, mixed> $over @return array<string, mixed> */
    public static function hit(array $over = []): array
    {
        return [
            'project_id' => 'AANobbMI',
            'title' => 'Fabulously Optimized',
            'description' => 'Performance.',
            'downloads' => 1000,
            'icon_url' => 'https://cdn.modrinth.com/data/AANobbMI/icon.png',
            'project_type' => 'modpack',
            ...$over,
        ];
    }

    /** A subuser of the server with exactly these permissions. @param list<string> $permissions */
    public static function subuser(Server $server, array $permissions): User
    {
        $user = User::factory()->create();
        Subuser::query()->create(['user_id' => $user->id, 'server_id' => $server->id, 'permissions' => $permissions]);

        return $user;
    }
}

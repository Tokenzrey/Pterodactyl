<?php

declare(strict_types=1);

namespace FileTransfer\Tests;

use Pterodactyl\Models\Server;
use Pterodactyl\Models\Subuser;
use Pterodactyl\Models\User;

/** What the integration tests share: the URLs, a well-formed chunk request, and users with exactly some permissions. */
final class Uploads
{
    public const ID = '550e8400-e29b-41d4-a716-446655440000';

    public const OTHER_ID = '6ba7b810-9dad-41d1-80b4-00c04fd430c8';

    public static function url(Server $server, string $tail): string
    {
        return "/api/client/servers/{$server->uuid}/extensions/file-transfer/{$tail}";
    }

    /** The body of a chunk request for these bytes, with a correct checksum unless a test overrides it. @return array<string, mixed> */
    public static function chunk(string $uploadId, int $index, int $total, string $bytes, string $filename = 'pack.zip'): array
    {
        return [
            'upload_id' => $uploadId,
            'index' => $index,
            'total_chunks' => $total,
            'filename' => $filename,
            'checksum' => hash('sha256', $bytes),
            'data' => base64_encode($bytes),
        ];
    }

    /** The body of a merge request for a file made of these bytes. @return array<string, mixed> */
    public static function merge(string $uploadId, string $whole, string $directory = 'mods', string $filename = 'pack.zip'): array
    {
        return ['upload_id' => $uploadId, 'filename' => $filename, 'target_directory' => $directory, 'total_checksum' => hash('sha256', $whole)];
    }

    /** A subuser of the server with exactly these permissions. @param list<string> $permissions */
    public static function subuser(Server $server, array $permissions): User
    {
        $user = User::factory()->create();
        Subuser::query()->create(['user_id' => $user->id, 'server_id' => $server->id, 'permissions' => $permissions]);

        return $user;
    }
}

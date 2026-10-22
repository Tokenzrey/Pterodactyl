<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

use Pterodactyl\Models\Server;

/**
 * Routed mode's view of a server's name: the host name it gets, and whether another Minecraft server already has it.
 * The form (SubdomainFields) and the rename listeners use these, so they agree with each other and with games sync.
 */
final class RoutedNames
{
    /** The egg name games sync looks for (lib/games.py minecraft_servers). */
    public static function isMinecraft(Server $server): bool
    {
        return str_contains(strtolower((string) $server->egg?->name), 'minecraft');
    }

    /** The host name of the server: the slug of its name. Empty when the name gives none. */
    public static function label(Server $server): string
    {
        return Labels::slugFromName((string) $server->name);
    }

    /**
     * The routing status the screens show for a server (FR-R5), or null when the mode has no router to route through
     * (per-port). Worked out from Panel data only: no Cloudflare call and no read of the router's file.
     *
     * @return array{state: 'ready'|'invalid', reason: string|null}|null
     */
    public static function status(Server $server, string $mode): ?array
    {
        if ($mode !== 'routed') {
            return null;
        }

        $slug = self::label($server);

        return Status::evaluate(
            self::isMinecraft($server),
            $server->isSuspended(),
            $server->allocation?->ip,
            $slug,
            $slug !== '' && self::takenBy($server, $slug) !== null,
        );
    }

    /** The name of another Minecraft server that gives the same host name, or null. */
    public static function takenBy(Server $server, string $slug): ?string
    {
        return Server::query()
            ->where('id', '!=', $server->id)
            ->whereHas('egg', fn ($egg) => $egg->where('name', 'like', '%minecraft%'))
            ->pluck('name')
            ->first(fn (string $name): bool => Labels::slugFromName($name) === $slug);
    }
}

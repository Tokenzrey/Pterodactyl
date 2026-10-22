<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

/**
 * Whether a server's name will be routed by mc-router, worked out from data the Panel already has. The rules are
 * the ones `build_routes` in lib/games.py applies, so the page never claims a route the router does not have.
 * Nothing here calls Cloudflare or the router's file (NFR-R1): the router's file is on the host, not in the Panel.
 */
final class Status
{
    /** Loopback names `build_routes` accepts for an allocation (games.py LOOPBACK). */
    private const LOOPBACK = ['127.0.0.1', 'localhost'];

    /**
     * @param  bool  $minecraftEgg  the server's egg is a Minecraft one (its name contains "minecraft")
     * @param  string|null  $allocationIp  the primary allocation's address, or null when the Panel does not show it
     * @param  string  $slug  Labels::slugFromName of the server's name
     * @param  bool  $conflict  another server gives the same slug (see slugTaken)
     * @return array{state: 'ready'|'invalid', reason: string|null}|null null for servers that are not routed at all
     */
    public static function evaluate(bool $minecraftEgg, bool $suspended, ?string $allocationIp, string $slug, bool $conflict): ?array
    {
        if (! $minecraftEgg) {
            return null;
        }
        if ($suspended) {
            return self::invalid('the server is suspended');
        }
        if ($allocationIp === null) {
            return self::invalid('the allocation is not visible');
        }
        if (! in_array($allocationIp, self::LOOPBACK, true)) {
            return self::invalid("the allocation is {$allocationIp}, not 127.0.0.1");
        }
        if ($slug === '') {
            return self::invalid('the name does not give a host name');
        }
        if ($conflict) {
            return self::invalid('another server already has this host name');
        }

        return ['state' => 'ready', 'reason' => null];
    }

    /** Whether another server's name gives the same host name. An empty slug is never taken: it has its own reason. */
    public static function slugTaken(string $slug, iterable $otherNames): bool
    {
        if ($slug === '') {
            return false;
        }
        foreach ($otherNames as $name) {
            if (Labels::slugFromName((string) $name) === $slug) {
                return true;
            }
        }

        return false;
    }

    /** @return array{state: 'invalid', reason: string} */
    private static function invalid(string $reason): array
    {
        return ['state' => 'invalid', 'reason' => $reason];
    }
}

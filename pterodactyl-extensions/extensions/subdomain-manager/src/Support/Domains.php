<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

/**
 * The `domains` setting: a list of "domain:zone_id" items. A zone id is 32 lower-case hex digits and a
 * domain a plain host name, so neither can smuggle anything into a URL or a record name.
 */
final class Domains
{
    public const ZONE_PATTERN = '/^[a-f0-9]{32}$/D';

    /**
     * Longest domain that still leaves room for a 63 character label and the `_minecraft._tcp.` prefix
     * inside the 253 characters a DNS name may have.
     */
    private const MAX_LENGTH = 173;

    /** Two or more DNS labels, the last one not all digits (so an IP address is never a domain). */
    private const HOSTNAME_PATTERN = '/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D';

    /**
     * @param  array<mixed>  $items
     * @return array<string, string> domain => zone id; broken items and repeats of a domain are left out
     */
    public static function parse(array $items): array
    {
        $domains = [];
        foreach ($items as $item) {
            $entry = self::split($item);
            if ($entry !== null && ! isset($domains[$entry[0]])) {
                $domains[$entry[0]] = $entry[1];
            }
        }

        return $domains;
    }

    /**
     * The items parse() ignores, as given, so a settings form can name them.
     *
     * @param  array<mixed>  $items
     * @return list<mixed>
     */
    public static function invalid(array $items): array
    {
        $seen = [];
        $invalid = [];
        foreach ($items as $item) {
            $entry = self::split($item);
            if ($entry === null || isset($seen[$entry[0]])) {
                $invalid[] = $item;

                continue;
            }
            $seen[$entry[0]] = true;
        }

        return $invalid;
    }

    /**
     * @param  array<mixed>  $items
     * @return list<string> the domains that parse() keeps, in the order given
     */
    public static function names(array $items): array
    {
        return array_keys(self::parse($items));
    }

    public static function isHostname(string $domain): bool
    {
        return strlen($domain) <= self::MAX_LENGTH && preg_match(self::HOSTNAME_PATTERN, $domain) === 1 && preg_match('/[a-z-]/', substr($domain, (int) strrpos($domain, '.') + 1)) === 1;
    }

    /** @return array{string, string}|null [domain, zone id] */
    private static function split(mixed $item): ?array
    {
        if (! is_string($item) || ! str_contains($item, ':')) {
            return null;
        }

        // Only spaces are forgiven; a newline or tab inside an item means something is wrong with it.
        [$domain, $zone] = array_map(fn (string $part): string => trim($part, ' '), explode(':', $item, 2));
        $domain = strtolower($domain);

        return self::isHostname($domain) && preg_match(self::ZONE_PATTERN, $zone) === 1 ? [$domain, $zone] : null;
    }
}

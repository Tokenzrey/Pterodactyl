<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

/**
 * Where a modpack may be downloaded from. The address comes from the source's own API, never from the browser, but it is
 * still not trusted: only https on CurseForge's own CDN domains is followed, so a hostile or compromised answer cannot
 * turn the Panel into a client for an internal service (T-MI1).
 */
final class DownloadUrlValidator
{
    /** A host is allowed if it is one of these or a subdomain of one. */
    private const DOMAINS = ['forgecdn.net', 'curseforge.com'];

    /** Null when the address may be fetched, otherwise 'invalid_url'. */
    public static function validate(string $url): ?string
    {
        if ($url === '' || strlen($url) > 2048 || preg_match('/[\x00-\x20\x7f]/', $url) === 1) {
            return 'invalid_url';
        }

        $parts = parse_url($url);
        if ($parts === false || strtolower((string) ($parts['scheme'] ?? '')) !== 'https') {
            return 'invalid_url';
        }
        if (isset($parts['user']) || isset($parts['pass']) || (isset($parts['port']) && $parts['port'] !== 443)) {
            return 'invalid_url';
        }

        $host = strtolower(rtrim((string) ($parts['host'] ?? ''), '.'));
        foreach (self::DOMAINS as $domain) {
            if ($host === $domain || str_ends_with($host, ".{$domain}")) {
                return null;
            }
        }

        return 'invalid_url';
    }
}

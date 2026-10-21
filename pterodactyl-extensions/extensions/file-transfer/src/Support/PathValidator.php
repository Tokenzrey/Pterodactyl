<?php

declare(strict_types=1);

namespace FileTransfer\Support;

/**
 * The directory a file is delivered to, relative to the server's root. "." is the root itself. Nothing that could
 * climb out of the server's files (a ".." anywhere, an absolute path, a backslash, an odd character) is accepted
 * (NFR-FT7, FR-FT20).
 */
final class PathValidator
{
    private const MAX_LENGTH = 255;

    public static function validate(string $path): ?string
    {
        // \A and \z, not ^ and $: a trailing newline must not pass as the end of the path.
        if ($path === '' || strlen($path) > self::MAX_LENGTH
            || str_starts_with($path, '/') || str_contains($path, '..') || str_contains($path, '//')
            || preg_match('/\A[a-zA-Z0-9_\-\/.]+\z/', $path) !== 1) {
            return 'invalid_target_directory';
        }

        return null;
    }

    /** The path of a file on the server: "/mods/pack.zip" for "mods", "/pack.zip" for the root ".". Both parts are validated. */
    public static function join(string $directory, string $filename): string
    {
        $segments = array_filter(explode('/', $directory), static fn (string $segment): bool => $segment !== '' && $segment !== '.');

        return '/'.implode('/', [...$segments, $filename]);
    }
}

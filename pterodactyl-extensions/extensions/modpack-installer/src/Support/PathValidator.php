<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

/**
 * The folder a modpack is installed into, relative to the server's root. "." is the root itself. Nothing that could
 * climb out of the server's files is accepted: a ".." anywhere, an absolute path, a backslash, an odd character
 * (FR-MI5, FR-MI19, NFR-MI9).
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

    /** The path of a file on the server: "/mods/pack.zip" for "mods", "/pack.zip" for the root ".". */
    public static function join(string $directory, string $filename): string
    {
        return '/'.implode('/', [...self::segments($directory), $filename]);
    }

    /** The path of a folder on the server: "/mods" for "mods", "/" for the root. */
    public static function absolute(string $directory): string
    {
        return '/'.implode('/', self::segments($directory));
    }

    /** @return list<string> */
    private static function segments(string $directory): array
    {
        return array_values(array_filter(explode('/', $directory), static fn (string $segment): bool => $segment !== '' && $segment !== '.'));
    }
}

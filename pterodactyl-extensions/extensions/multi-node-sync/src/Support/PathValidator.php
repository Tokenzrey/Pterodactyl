<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

final class PathValidator
{
    // \A…\z, not ^…$: "$" also matches before a trailing newline, which would let "key\n" through into a URL or a path.
    private const VALID_PATTERN = '/\A[a-zA-Z0-9_\-\/.]+\z/';

    /**
     * A relative path of letters, digits and "_", "-", "." and "/": no leading slash, no empty, "." or ".." segment
     * (so no "//", no trailing "/"), and no ".." anywhere. Null when it is fine, otherwise 'invalid_path'.
     */
    public static function validate(string $path, int $maxLength = 255): ?string
    {
        if ($path === '' || strlen($path) > $maxLength) {
            return 'invalid_path';
        }

        if (str_starts_with($path, '/') || str_contains($path, '..')) {
            return 'invalid_path';
        }

        if (preg_match(self::VALID_PATTERN, $path) !== 1) {
            return 'invalid_path';
        }

        foreach (explode('/', $path) as $segment) {
            if ($segment === '' || $segment === '.') {
                return 'invalid_path';
            }
        }

        return null;
    }
}

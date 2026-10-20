<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use Illuminate\Support\Str;

/** Builds a username the Panel accepts (/^[a-z0-9]([\w.-]+)[a-z0-9]$/) and that is not taken yet. */
final class Usernames
{
    private const ATTEMPTS = 5;

    private const MAX_BASE = 24;

    /**
     * @param  callable(string): bool  $exists  true when the candidate is already a username
     * @return string|null null after 5 taken candidates
     */
    public static function generate(string $hint, callable $exists): ?string
    {
        $base = self::clean($hint);

        for ($attempt = 0; $attempt < self::ATTEMPTS; $attempt++) {
            // First try the bare name when it is long enough; every later try adds a random suffix.
            $candidate = $attempt === 0 && strlen($base) >= 3
                ? $base
                : ($base === '' ? 'user' : $base).'-'.bin2hex(random_bytes(2));

            if (! $exists($candidate)) {
                return $candidate;
            }
        }

        return null;
    }

    /** ASCII lower-case [a-z0-9._-], starting and ending with a letter or digit, at most 24 characters. */
    private static function clean(string $hint): string
    {
        $hint = mb_check_encoding($hint, 'UTF-8') ? Str::ascii($hint) : '';
        $hint = preg_replace('/[^a-z0-9._-]+/', '_', strtolower($hint)) ?? '';

        return trim(substr(trim($hint, '._-'), 0, self::MAX_BASE), '._-');
    }
}

<?php

declare(strict_types=1);

namespace OauthLogin\Support;

/**
 * Turns decoded provider responses into a Profile, or null when the account cannot be trusted:
 * no email, or an email the provider has not verified. Flags must be real booleans; "true" or 1
 * from a Discord/GitHub payload is treated as unverified (Google's string "true" is accepted
 * because some of its endpoints serialise the flag that way).
 */
final class ProfileParser
{
    /** users.email is varchar(191). */
    private const MAX_EMAIL = 191;

    /** @param array<mixed> $me */
    public static function discord(array $me): ?Profile
    {
        if (($me['verified'] ?? null) !== true) {
            return null;
        }

        $id = self::id($me['id'] ?? null);
        $email = self::email($me['email'] ?? null);
        $name = self::text($me['username'] ?? null);
        if ($id === null || $email === null || $name === '') {
            return null;
        }

        return new Profile($id, $email, $name, self::text($me['global_name'] ?? null) ?: $name);
    }

    /**
     * @param  array<mixed>  $user
     * @param  array<mixed>  $emails  the /user/emails list; only the primary, verified entry counts
     */
    public static function github(array $user, array $emails): ?Profile
    {
        $id = self::id($user['id'] ?? null);
        $login = self::text($user['login'] ?? null);
        if ($id === null || $login === '') {
            return null;
        }

        foreach ($emails as $entry) {
            if (! is_array($entry) || ($entry['primary'] ?? null) !== true || ($entry['verified'] ?? null) !== true) {
                continue;
            }
            if (($email = self::email($entry['email'] ?? null)) !== null) {
                return new Profile($id, $email, $login, self::text($user['name'] ?? null) ?: $login);
            }
        }

        return null;
    }

    /** @param array<mixed> $info */
    public static function google(array $info): ?Profile
    {
        if (! in_array($info['email_verified'] ?? null, [true, 'true'], true)) {
            return null;
        }

        $id = self::id($info['sub'] ?? null);
        $email = self::email($info['email'] ?? null);
        if ($id === null || $email === null) {
            return null;
        }

        return new Profile($id, $email, strstr($email, '@', true), self::text($info['name'] ?? null));
    }

    /** Provider ids are strings or integers; floats would already have lost precision. */
    private static function id(mixed $value): ?string
    {
        $id = match (true) {
            is_int($value) => (string) $value,
            is_string($value) => $value,
            default => '',
        };

        return $id !== '' && strlen($id) <= 255 ? $id : null;
    }

    private static function text(mixed $value): string
    {
        return is_string($value) ? trim($value) : '';
    }

    /** Lower-cased address with no whitespace or control characters (mail header injection) and one "@". Not trimmed: a verified address has no padding. */
    private static function email(mixed $value): ?string
    {
        if (! is_string($value)) {
            return null;
        }

        $email = mb_strtolower($value);

        return mb_strlen($email) <= self::MAX_EMAIL && preg_match('/^[^\s@\p{Z}\p{C}]+@[^\s@\p{Z}\p{C}]+$/Du', $email) === 1
            ? $email
            : null;
    }
}

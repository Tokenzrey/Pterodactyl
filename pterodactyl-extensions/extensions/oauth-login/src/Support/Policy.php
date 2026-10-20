<?php

declare(strict_types=1);

namespace OauthLogin\Support;

/**
 * Who may sign in through a provider. Runs before a link or account is created, so a refused
 * user never gains an identity row. Anything but the explicit "trust_provider" blocks 2FA users.
 */
final class Policy
{
    public const TRUST_PROVIDER = 'trust_provider';

    /** @return string|null the error code, or null when sign-in may proceed */
    public static function check(bool $rootAdmin, bool $usesTotp, bool $allowAdminLogin, string $twoFactorPolicy): ?string
    {
        return match (true) {
            $rootAdmin && ! $allowAdminLogin => Errors::ADMIN_BLOCKED,
            $usesTotp && $twoFactorPolicy !== self::TRUST_PROVIDER => Errors::TWO_FACTOR_REQUIRED,
            default => null,
        };
    }
}

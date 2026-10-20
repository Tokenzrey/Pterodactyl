<?php

declare(strict_types=1);

namespace OauthLogin\Support;

/**
 * The only error codes a failed sign-in can carry back to the login page (FR-O13). Provider
 * messages and exception texts are never forwarded; the page maps each code to its own wording.
 */
final class Errors
{
    public const DENIED = 'denied';

    public const INVALID_STATE = 'invalid_state';

    public const PROVIDER_ERROR = 'provider_error';

    public const EMAIL_UNVERIFIED = 'email_unverified';

    public const NO_ACCOUNT = 'no_account';

    public const ADMIN_BLOCKED = 'admin_blocked';

    public const TWO_FACTOR_REQUIRED = 'two_factor_required';

    public const IDENTITY_CONFLICT = 'identity_conflict';

    public const REGISTRATION_FAILED = 'registration_failed';

    public const PROVIDER_UNAVAILABLE = 'provider_unavailable';

    public const ALL = [
        self::DENIED, self::INVALID_STATE, self::PROVIDER_ERROR, self::EMAIL_UNVERIFIED, self::NO_ACCOUNT,
        self::ADMIN_BLOCKED, self::TWO_FACTOR_REQUIRED, self::IDENTITY_CONFLICT, self::REGISTRATION_FAILED, self::PROVIDER_UNAVAILABLE,
    ];

    /** The page where a signed-in user manages connected accounts; connect flows end here, with a result in the query. */
    public const ACCOUNT_PAGE = '/account/connected-accounts';

    /** Where a failed connect attempt ends up. The code comes from ALL, never from the request. */
    public static function accountUrl(string $code): string
    {
        return self::ACCOUNT_PAGE.'?oauth_error='.$code;
    }

    public static function linkedUrl(Provider $provider): string
    {
        return self::ACCOUNT_PAGE.'?oauth_linked='.$provider->value;
    }

    /** Where a failed attempt ends up. The code comes from ALL, never from the request. */
    public static function loginUrl(string $code): string
    {
        return '/auth/login?oauth_error='.$code;
    }
}

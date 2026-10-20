<?php

declare(strict_types=1);

namespace OauthLogin\Support;

final class RedirectUri
{
    /**
     * The callback URL registered at the provider. Built from APP_URL only: a request's Host or
     * X-Forwarded-* headers never take part (FR-O4), so they cannot redirect a code elsewhere.
     */
    public static function for(Provider $provider): string
    {
        return rtrim((string) config('app.url'), '/').'/extensions/oauth-login/callback/'.$provider->value;
    }
}

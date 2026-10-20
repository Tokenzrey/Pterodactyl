<?php

declare(strict_types=1);

namespace OauthLogin\Support;

final class AuthUrl
{
    /** Authorisation URL for the provider. Values are RFC 3986 encoded, so none can add a parameter. */
    public static function build(Provider $provider, string $clientId, string $redirectUri, Flow $flow): string
    {
        $query = [
            'response_type' => 'code',
            'client_id' => $clientId,
            'redirect_uri' => $redirectUri,
            'scope' => $provider->scopes(),
            'state' => $flow->state,
        ];

        if (($challenge = $flow->challenge()) !== null) {
            $query += ['code_challenge' => $challenge, 'code_challenge_method' => 'S256'];
        }

        return $provider->authorizeUrl().'?'.http_build_query($query, '', '&', PHP_QUERY_RFC3986);
    }
}
